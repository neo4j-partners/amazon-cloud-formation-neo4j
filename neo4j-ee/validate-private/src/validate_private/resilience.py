"""Resilience test cases for EE Private clusters.

single-loss: terminate one cluster node; verify volume reattach + data persistence
             + quorum reform.
total-loss:  terminate all three nodes simultaneously; verify all three volumes
             reattach + sentinel intact + quorum from retained volumes.

Both cases use a marker file dropped on the data volume before termination.
Marker present on the replacement instance = volume was reattached (not reformatted).
"""

from __future__ import annotations

import concurrent.futures
import logging
import time
import uuid
from typing import TYPE_CHECKING

from botocore.config import Config
from validate_private.runner import Neo4jQueryError, run_cypher_on_bastion, run_shell_on_instance

if TYPE_CHECKING:
    from validate_private.config import StackConfig
    from validate_private.reporting import TestReporter

log = logging.getLogger(__name__)

_MARKER_PATH = "/var/lib/neo4j/data/.resilience-marker-{}"
_ASG_LOGICAL_IDS = ("Neo4jNode1ASG", "Neo4jNode2ASG", "Neo4jNode3ASG")
_RETRY_CFG = Config(retries={"mode": "standard"})


# ---------------------------------------------------------------------------
# AWS helpers — accept pre-created clients; no boto3 imports inside helpers
# ---------------------------------------------------------------------------

def _stack_resources(cfn, stack_name: str) -> dict[str, str]:
    paginator = cfn.get_paginator("list_stack_resources")
    result = {}
    for page in paginator.paginate(StackName=stack_name):
        for r in page["StackResourceSummaries"]:
            result[r["LogicalResourceId"]] = r["PhysicalResourceId"]
    return result


def _asg_instances(asg, asg_name: str) -> list[str]:
    """Return InService instance IDs in an ASG."""
    groups = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])["AutoScalingGroups"]
    if not groups:
        return []
    return [i["InstanceId"] for i in groups[0]["Instances"] if i["LifecycleState"] == "InService"]


def _terminate_instance(ec2, instance_id: str) -> None:
    ec2.terminate_instances(InstanceIds=[instance_id])


def _wait_for_new_instance(
    asg,
    asg_name: str,
    prior_ids: set[str],
    timeout: int,
) -> str:
    """Poll until the ASG has an InService instance not in prior_ids. Returns the new ID."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        groups = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])["AutoScalingGroups"]
        instances = (
            [i["InstanceId"] for i in groups[0]["Instances"] if i["LifecycleState"] == "InService"]
            if groups else []
        )
        candidates = [i for i in instances if i not in prior_ids]
        if candidates:
            return candidates[0]
        time.sleep(15)
    raise TimeoutError(
        f"ASG {asg_name} did not produce a replacement within {timeout}s. "
        "Check ASG activity history and instance UserData logs."
    )


def _wait_all_replaced(
    asg,
    asg_prior: dict[str, set[str]],
    timeout: int,
) -> dict[str, str]:
    """Wait until every ASG in asg_prior has a new InService instance.

    asg_prior maps asg_name -> set of instance IDs that existed before termination.
    Returns asg_name -> new_instance_id.
    """
    deadline = time.monotonic() + timeout
    remaining = dict(asg_prior)
    new_instances: dict[str, str] = {}

    while remaining and time.monotonic() < deadline:
        for asg_name, prior_ids in list(remaining.items()):
            groups = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])["AutoScalingGroups"]
            instances = (
                [i["InstanceId"] for i in groups[0]["Instances"] if i["LifecycleState"] == "InService"]
                if groups else []
            )
            candidates = [i for i in instances if i not in prior_ids]
            if candidates:
                new_instances[asg_name] = candidates[0]
                del remaining[asg_name]
                log.info("  Replacement ready: %s → %s", asg_name, candidates[0])
        if remaining:
            time.sleep(15)

    if remaining:
        missing = ", ".join(remaining)
        raise TimeoutError(
            f"ASGs [{missing}] did not produce replacements within {timeout}s. "
            "This may mean the cluster never reformed quorum — check ASG activity "
            "and /var/log/cloud-init-output.log on partial replacements."
        )
    return new_instances


def _wait_ssm_online(ssm, instance_id: str, timeout: int = 300) -> bool:
    """Poll SSM until the instance PingStatus is Online."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        resp = ssm.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [instance_id]}]
        )
        items = resp.get("InstanceInformationList", [])
        if items and items[0].get("PingStatus") == "Online":
            return True
        time.sleep(10)
    return False


# ---------------------------------------------------------------------------
# Marker file: volume reattach verification
# ---------------------------------------------------------------------------

def _drop_marker(ssm, instance_id: str, marker_id: str) -> bool:
    """Touch the marker file on the data volume via SSM. Returns True on success."""
    path = _MARKER_PATH.format(marker_id)
    ok, _, err = run_shell_on_instance(ssm, instance_id, f"touch {path} && echo ok")
    if not ok:
        log.warning("  Failed to drop marker on %s: %s", instance_id, err)
    return ok


def _check_marker(ssm, instance_id: str, marker_id: str) -> bool:
    """Return True if the marker file exists on the instance's data volume."""
    path = _MARKER_PATH.format(marker_id)
    ok, stdout, _ = run_shell_on_instance(
        ssm, instance_id, f"test -f {path} && echo FOUND || echo MISSING"
    )
    return ok and "FOUND" in stdout


# ---------------------------------------------------------------------------
# Neo4j checks via bastion
# ---------------------------------------------------------------------------

def _wait_neo4j(config: "StackConfig", timeout: int) -> bool:
    """Retry a trivial Cypher query via the bastion until Neo4j is reachable."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            rows = run_cypher_on_bastion(config, "RETURN 1 AS ok", timeout_s=30)
            if rows and rows[0].get("ok") == 1:
                return True
        except Exception:
            pass
        time.sleep(15)
    return False


def _write_sentinel(config: "StackConfig", test_run_id: str) -> tuple[bool, str]:
    try:
        run_cypher_on_bastion(
            config,
            "CREATE (s:ResilienceSentinel {test_id: $tid, value: 'persistence-check'})",
            params={"tid": test_run_id},
        )
        rows = run_cypher_on_bastion(
            config,
            "MATCH (s:ResilienceSentinel {test_id: $tid}) RETURN s.value AS v",
            params={"tid": test_run_id},
        )
        if rows and rows[0].get("v") == "persistence-check":
            return True, f"Sentinel written (id={test_run_id[:8]}…)"
        return False, "Sentinel not found immediately after creation"
    except (Neo4jQueryError, Exception) as exc:
        return False, str(exc)


def _verify_sentinel(config: "StackConfig", test_run_id: str) -> tuple[bool, str]:
    try:
        rows = run_cypher_on_bastion(
            config,
            "MATCH (s:ResilienceSentinel {test_id: $tid}) RETURN s.value AS v",
            params={"tid": test_run_id},
        )
        if not rows:
            return False, "Sentinel NOT found — data volume was lost or reformatted"
        if rows[0].get("v") == "persistence-check":
            return True, f"Sentinel intact (id={test_run_id[:8]}…)"
        return False, f"Unexpected sentinel value: {rows[0].get('v')!r}"
    except (Neo4jQueryError, Exception) as exc:
        return False, str(exc)


def _cleanup_sentinel(config: "StackConfig", test_run_id: str) -> None:
    try:
        run_cypher_on_bastion(
            config,
            "MATCH (s:ResilienceSentinel {test_id: $tid}) DELETE s",
            params={"tid": test_run_id},
        )
    except Exception:
        log.warning("  Sentinel cleanup failed (non-fatal) — run manually if needed:")
        log.warning("    MATCH (s:ResilienceSentinel {test_id: '%s'}) DELETE s", test_run_id)


def _check_quorum(
    config: "StackConfig",
    reporter: "TestReporter",
    expected_nodes: int,
) -> None:
    """Verify cluster quorum: expected node count, all healthy, exactly 1 writer."""
    start = time.monotonic()
    try:
        server_rows = run_cypher_on_bastion(config, "SHOW SERVERS", database="system")
        actual_count = len(server_rows)
        unhealthy = [
            r.get("name", r.get("serverId", "?"))
            for r in server_rows
            if r.get("health") != "Available" or r.get("state") != "Enabled"
        ]

        routing_rows = run_cypher_on_bastion(
            config,
            "CALL dbms.routing.getRoutingTable({}) YIELD servers RETURN servers",
        )
        servers = routing_rows[0]["servers"] if routing_rows else []
        write_entry = next((s for s in servers if s["role"] == "WRITE"), None)
        read_entry = next((s for s in servers if s["role"] == "READ"), None)
        writer_count = len(write_entry["addresses"]) if write_entry else 0
        reader_count = len(read_entry["addresses"]) if read_entry else 0

        issues = []
        if actual_count != expected_nodes:
            issues.append(f"expected {expected_nodes} nodes, got {actual_count}")
        if unhealthy:
            issues.append(f"unhealthy: {unhealthy}")
        if writer_count != 1:
            issues.append(f"expected 1 writer, got {writer_count}")

        if issues:
            reporter.record(
                "Cluster quorum", False,
                "Quorum check failed: " + "; ".join(issues),
                time.monotonic() - start,
            )
        else:
            reporter.record(
                "Cluster quorum", True,
                f"{actual_count} nodes (1 writer, {reader_count} reader(s))",
                time.monotonic() - start,
            )
    except Exception as exc:
        reporter.record("Cluster quorum", False, str(exc), time.monotonic() - start)


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

def run_single_loss(
    config: "StackConfig",
    reporter: "TestReporter",
    timeout: int = 900,
) -> None:
    """Terminate one cluster node and verify volume reattach + data persistence."""
    import boto3

    log.info("=== Single-loss resilience test ===")
    log.info("")

    cfn = boto3.client("cloudformation", region_name=config.region, config=_RETRY_CFG)
    asg = boto3.client("autoscaling", region_name=config.region, config=_RETRY_CFG)
    ec2 = boto3.client("ec2", region_name=config.region, config=_RETRY_CFG)
    ssm = boto3.client("ssm", region_name=config.region, config=_RETRY_CFG)

    resources = _stack_resources(cfn, config.stack_name)
    asg_map = {k: resources[k] for k in _ASG_LOGICAL_IDS if k in resources}

    if len(asg_map) < 2:
        log.info(
            "Single-node deployment (found %d cluster ASG(s)) — "
            "single-loss test requires a 3-node cluster. Skipping.\n",
            len(asg_map),
        )
        return

    test_run_id = uuid.uuid4().hex

    start = time.monotonic()
    ok, detail = _write_sentinel(config, test_run_id)
    reporter.record("Write sentinel", ok, detail, time.monotonic() - start)
    if not ok:
        return

    target_asg = asg_map[_ASG_LOGICAL_IDS[0]]
    prior_instances = _asg_instances(asg, target_asg)
    if not prior_instances:
        reporter.record("Find target instance", False, f"No InService instances in {target_asg}", 0)
        return
    target = prior_instances[0]
    log.info("  Target: %s (ASG: %s)\n", target, target_asg)

    start = time.monotonic()
    ok = _drop_marker(ssm, target, test_run_id)
    reporter.record(
        "Drop volume marker", ok,
        f"Marker written on {target}" if ok else f"Could not write marker on {target}",
        time.monotonic() - start,
    )
    if not ok:
        return

    start = time.monotonic()
    try:
        _terminate_instance(ec2, target)
        reporter.record("Terminate cluster node", True, f"Terminated {target}", time.monotonic() - start)
    except Exception as exc:
        reporter.record("Terminate cluster node", False, str(exc), time.monotonic() - start)
        return

    log.info("  Waiting for ASG replacement (timeout: %ds)…\n", timeout)
    start = time.monotonic()
    try:
        new_instance = _wait_for_new_instance(asg, target_asg, set(prior_instances), timeout)
        reporter.record(
            "ASG replacement InService", True,
            f"{target} → {new_instance}",
            time.monotonic() - start,
        )
    except TimeoutError as exc:
        reporter.record("ASG replacement InService", False, str(exc), time.monotonic() - start)
        return

    log.info("  Waiting for SSM on %s…\n", new_instance)
    start = time.monotonic()
    ok = _wait_ssm_online(ssm, new_instance, timeout=300)
    reporter.record(
        "Replacement SSM ready", ok,
        f"{new_instance} is SSM Online" if ok else f"{new_instance} not SSM Online within 300s",
        time.monotonic() - start,
    )
    if not ok:
        return

    start = time.monotonic()
    found = _check_marker(ssm, new_instance, test_run_id)
    reporter.record(
        "Volume reattach (marker)", found,
        "Marker present — data volume was reattached" if found
        else "Marker MISSING — volume was reformatted or wrong volume attached",
        time.monotonic() - start,
    )

    log.info("  Waiting for Neo4j post-recovery (timeout: 300s)…\n")
    start = time.monotonic()
    ok = _wait_neo4j(config, timeout=300)
    reporter.record(
        "Neo4j reachable post-recovery", ok,
        "Accepting Cypher via bastion" if ok else "Neo4j not reachable within 300s",
        time.monotonic() - start,
    )
    if not ok:
        return

    start = time.monotonic()
    ok, detail = _verify_sentinel(config, test_run_id)
    reporter.record("Sentinel persisted", ok, detail, time.monotonic() - start)

    _check_quorum(config, reporter, expected_nodes=len(asg_map))
    _cleanup_sentinel(config, test_run_id)
    log.info("")


def run_total_loss(
    config: "StackConfig",
    reporter: "TestReporter",
    timeout: int = 1200,
) -> None:
    """Terminate all cluster nodes simultaneously and verify full cluster recovery."""
    import boto3

    log.info("=== Total-loss resilience test ===")
    log.info("")

    cfn = boto3.client("cloudformation", region_name=config.region, config=_RETRY_CFG)
    asg = boto3.client("autoscaling", region_name=config.region, config=_RETRY_CFG)
    ec2 = boto3.client("ec2", region_name=config.region, config=_RETRY_CFG)
    ssm = boto3.client("ssm", region_name=config.region, config=_RETRY_CFG)

    resources = _stack_resources(cfn, config.stack_name)
    asg_map = {k: resources[k] for k in _ASG_LOGICAL_IDS if k in resources}

    if len(asg_map) < 3:
        log.info(
            "Found %d cluster ASG(s) — total-loss test requires all 3. "
            "Is this a single-node or partial-cluster deployment? Skipping.\n",
            len(asg_map),
        )
        return

    test_run_id = uuid.uuid4().hex

    start = time.monotonic()
    ok, detail = _write_sentinel(config, test_run_id)
    reporter.record("Write sentinel", ok, detail, time.monotonic() - start)
    if not ok:
        return

    asg_prior: dict[str, set[str]] = {}
    target_instances: dict[str, str] = {}

    for logical, asg_name in asg_map.items():
        instances = _asg_instances(asg, asg_name)
        if not instances:
            reporter.record(
                "Find cluster instances", False,
                f"No InService instances in {asg_name} ({logical})", 0,
            )
            return
        asg_prior[asg_name] = set(instances)
        target_instances[logical] = instances[0]

    log.info("  Targets: %s\n", ", ".join(target_instances.values()))

    # Drop markers in parallel — each is a 120s-timeout SSM command; sequential
    # would triple the worst-case time.
    t0 = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as exe:
        drop_futs = {
            exe.submit(_drop_marker, ssm, iid, test_run_id): (logical, iid)
            for logical, iid in target_instances.items()
        }
        marker_ok = True
        for fut in concurrent.futures.as_completed(drop_futs):
            logical, iid = drop_futs[fut]
            ok = fut.result()
            reporter.record(
                f"Drop marker ({logical})", ok,
                f"Marker on {iid}" if ok else f"Could not write marker on {iid}",
                time.monotonic() - t0,
            )
            if not ok:
                marker_ok = False
    if not marker_ok:
        return

    # Terminate all three in parallel so they go down as simultaneously as possible.
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as exe:
        term_futs = {
            exe.submit(_terminate_instance, ec2, iid): (logical, iid, time.monotonic())
            for logical, iid in target_instances.items()
        }
        for fut in concurrent.futures.as_completed(term_futs):
            logical, iid, t_start = term_futs[fut]
            try:
                fut.result()
                reporter.record(f"Terminate {logical}", True, f"Terminated {iid}", time.monotonic() - t_start)
            except Exception as exc:
                reporter.record(f"Terminate {logical}", False, str(exc), time.monotonic() - t_start)

    log.info("  Waiting for all 3 ASG replacements (timeout: %ds)…\n", timeout)
    start = time.monotonic()
    try:
        new_instances = _wait_all_replaced(asg, asg_prior, timeout)
        reporter.record(
            "All ASGs replaced", True,
            f"New instances: {', '.join(new_instances.values())}",
            time.monotonic() - start,
        )
    except TimeoutError as exc:
        reporter.record("All ASGs replaced", False, str(exc), time.monotonic() - start)
        return

    # Wait for SSM online and check markers in parallel across all three replacements.
    # ssm is thread-safe (boto3 clients share a connection pool via urllib3).
    logical_map = {v: k for k, v in asg_map.items()}

    def _ssm_and_check(asg_name: str, new_instance: str) -> tuple[str, str, bool, float, bool, float]:
        logical = logical_map[asg_name]
        t_ssm = time.monotonic()
        ssm_ok = _wait_ssm_online(ssm, new_instance, timeout=300)
        ssm_elapsed = time.monotonic() - t_ssm
        t_check = time.monotonic()
        found = _check_marker(ssm, new_instance, test_run_id) if ssm_ok else False
        check_elapsed = time.monotonic() - t_check
        return logical, new_instance, ssm_ok, ssm_elapsed, found, check_elapsed

    log.info("  Waiting for SSM on all replacements…\n")
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as exe:
        check_futs = [
            exe.submit(_ssm_and_check, asg_name, new_instance)
            for asg_name, new_instance in new_instances.items()
        ]
        for fut in concurrent.futures.as_completed(check_futs):
            logical, new_instance, ssm_ok, ssm_elapsed, found, check_elapsed = fut.result()
            reporter.record(
                f"SSM ready ({logical})", ssm_ok,
                f"{new_instance} Online" if ssm_ok else f"{new_instance} not Online within 300s",
                ssm_elapsed,
            )
            reporter.record(
                f"Volume reattach ({logical})", found,
                "Marker present" if found else "Marker MISSING — volume may have been reformatted",
                check_elapsed,
            )

    # All 3 nodes must start and elect a leader before Neo4j accepts queries.
    log.info("  Waiting for Neo4j quorum post-recovery (timeout: 600s)…\n")
    start = time.monotonic()
    ok = _wait_neo4j(config, timeout=600)
    reporter.record(
        "Neo4j reachable post-recovery", ok,
        "Accepting Cypher via bastion" if ok
        else (
            "Neo4j not reachable within 600s — cluster did not reform quorum. "
            "Check /var/log/cloud-init-output.log and /var/log/neo4j/debug.log "
            "on each replacement instance."
        ),
        time.monotonic() - start,
    )
    if not ok:
        return

    start = time.monotonic()
    ok, detail = _verify_sentinel(config, test_run_id)
    reporter.record("Sentinel persisted", ok, detail, time.monotonic() - start)

    _check_quorum(config, reporter, expected_nodes=len(asg_map))
    _cleanup_sentinel(config, test_run_id)
    log.info("")
