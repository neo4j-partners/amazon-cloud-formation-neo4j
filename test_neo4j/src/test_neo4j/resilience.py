"""Resilience tests: EBS persistence (CE) and Raft cluster recovery (EE)."""

from __future__ import annotations

import logging
import uuid
from typing import TYPE_CHECKING

from test_neo4j.aws_helpers import (
    get_asg_instance_id,
    get_stack_resources,
    terminate_instance,
    wait_for_cluster_recovery,
    wait_for_replacement_instance,
)
from test_neo4j.config import StackConfig
from test_neo4j.movies_dataset import (
    cleanup_movies_dataset,
    create_movies_dataset,
    verify_movies_dataset,
)
from test_neo4j.neo4j_checks import run_simple_tests
from test_neo4j.reporting import TestReporter
from test_neo4j.volume_checks import run_volume_checks
from test_neo4j.wait import wait_for_neo4j

if TYPE_CHECKING:
    import boto3

log = logging.getLogger(__name__)


def _write_sentinel(config: StackConfig, reporter: TestReporter, test_run_id: str) -> bool:
    """Create a sentinel node and verify it was written. Return True on success."""
    with reporter.test("Write sentinel data") as ctx:
        try:
            with config.driver() as driver:
                driver.execute_query(
                    "CREATE (s:Sentinel {test_id: $tid, value: $val})",
                    tid=test_run_id,
                    val="persistence-check",
                )
                records, _, _ = driver.execute_query(
                    "MATCH (s:Sentinel {test_id: $tid}) RETURN s.value AS value",
                    tid=test_run_id,
                )
                if records and records[0]["value"] == "persistence-check":
                    ctx.pass_(f"Sentinel node created (test_id={test_run_id[:8]}...)")
                    return True
                ctx.fail("Sentinel node not found immediately after creation")
                return False
        except Exception as exc:
            ctx.fail(f"Failed to write sentinel data: {exc}")
            return False


def _terminate_and_wait(
    config: StackConfig,
    reporter: TestReporter,
    session: boto3.Session,
    resource_map: dict[str, str],
    replacement_timeout: int,
) -> bool:
    """Terminate the current instance and wait for a healthy replacement. Return True on success."""
    original_instance_id = get_asg_instance_id(
        session, config.stack_name, resource_map
    )
    log.info("  Original instance: %s\n", original_instance_id)

    with reporter.test("Terminate EC2 instance") as ctx:
        try:
            terminate_instance(session, original_instance_id)
            ctx.pass_(f"Terminated {original_instance_id}")
        except Exception as exc:
            ctx.fail(f"Failed to terminate instance: {exc}")
            return False

    with reporter.test("Wait for ASG replacement") as ctx:
        try:
            new_instance_id = wait_for_replacement_instance(
                session,
                config.stack_name,
                resource_map,
                exclude_instance=original_instance_id,
                timeout=replacement_timeout,
            )
            ctx.pass_(
                f"Replacement {new_instance_id} is InService "
                f"(was {original_instance_id})"
            )
        except Exception as exc:
            ctx.fail(str(exc))
            return False

    log.info("Waiting for Neo4j on the replacement instance...")
    if not wait_for_neo4j(config, timeout=300, interval=10):
        with reporter.test("Post-recovery Neo4j readiness") as ctx:
            ctx.fail("Neo4j did not become reachable on the replacement within 300s")
        return False
    return True


def _verify_sentinel(config: StackConfig, reporter: TestReporter, test_run_id: str) -> None:
    """Check that the sentinel node survived instance replacement."""
    with reporter.test("Verify sentinel data persisted") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "MATCH (s:Sentinel {test_id: $tid}) RETURN s.value AS value",
                    tid=test_run_id,
                )
                if not records:
                    ctx.fail(
                        "Sentinel node NOT found after instance replacement. "
                        "EBS data volume was lost or reformatted."
                    )
                elif records[0]["value"] == "persistence-check":
                    ctx.pass_(
                        f"Sentinel node persisted across instance replacement "
                        f"(test_id={test_run_id[:8]}...)"
                    )
                else:
                    ctx.fail(f"Unexpected sentinel value: {records[0]['value']}")
        except Exception as exc:
            ctx.fail(f"Failed to query sentinel data: {exc}")


def _cleanup_sentinel(config: StackConfig, test_run_id: str) -> None:
    """Delete the sentinel node (best-effort, does not affect test results)."""
    try:
        with config.driver() as driver:
            driver.execute_query(
                "MATCH (s:Sentinel {test_id: $tid}) DELETE s",
                tid=test_run_id,
            )
        log.info("  Cleaned up sentinel node.\n")
    except Exception:
        log.warning("  Could not clean up sentinel node (non-fatal).\n")


def _check_cluster_overview(
    config: StackConfig,
    reporter: TestReporter,
    expected_nodes: int,
) -> None:
    """Verify the cluster has reformed: expected node count with exactly one writer.

    dbms.cluster.overview() was removed in Neo4j 5. Uses SHOW SERVERS (system db)
    for node count + health, and dbms.routing.getRoutingTable for writer/reader split.
    """
    with reporter.test("Cluster overview after node replacement") as ctx:
        try:
            with config.driver() as driver:
                server_records, _, _ = driver.execute_query(
                    "SHOW SERVERS",
                    database_="system",
                )
                actual_count = len(server_records)
                unhealthy = [
                    r["name"]
                    for r in server_records
                    if r["health"] != "Available" or r["state"] != "Enabled"
                ]

                routing_records, _, _ = driver.execute_query(
                    "CALL dbms.routing.getRoutingTable({}) YIELD servers RETURN servers"
                )
                servers = routing_records[0]["servers"]
                write_entry = next((s for s in servers if s["role"] == "WRITE"), None)
                read_entry = next((s for s in servers if s["role"] == "READ"), None)
                writer_count = len(write_entry["addresses"]) if write_entry else 0
                reader_count = len(read_entry["addresses"]) if read_entry else 0

                issues = []
                if actual_count != expected_nodes:
                    issues.append(f"expected {expected_nodes} nodes, got {actual_count}")
                if unhealthy:
                    issues.append(f"unhealthy nodes: {unhealthy}")
                if writer_count != 1:
                    issues.append(f"expected 1 writer, got {writer_count}")

                if not issues:
                    ctx.pass_(
                        f"Cluster has {actual_count} nodes "
                        f"(1 writer, {reader_count} reader(s))"
                    )
                else:
                    ctx.fail(f"Cluster check failed: {'; '.join(issues)}")
        except Exception as exc:
            ctx.fail(f"Failed to query cluster state: {exc}")


def run_ee_resilience_tests(
    config: StackConfig,
    reporter: TestReporter,
    session: boto3.Session,
    replacement_timeout: int = 600,
    resource_map: dict[str, str] | None = None,
    tunnel_instance_id: str | None = None,
) -> None:
    """EE Raft resilience: terminate one cluster node, verify ASG replacement and cluster reformation.

    *tunnel_instance_id* is the instance the SSM tunnel is connected to. When provided,
    that instance is excluded from termination so the tunnel remains live throughout
    the test, including the post-recovery readiness check.
    """
    if resource_map is None:
        resource_map = get_stack_resources(session, config.stack_name)

    asg_name = resource_map.get("Neo4jAutoScalingGroup")
    if not asg_name:
        log.info("EE resilience: ASG not found in resource map — skipping.\n")
        return

    asg_client = session.client("autoscaling")
    groups = asg_client.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )["AutoScalingGroups"]
    if not groups:
        log.info("EE resilience: ASG %s not found — skipping.\n", asg_name)
        return

    expected_nodes = groups[0]["DesiredCapacity"]
    if expected_nodes < 2:
        log.info(
            "EE resilience: single-instance deployment (DesiredCapacity=%d) — "
            "Raft resilience test requires a cluster, skipping.\n",
            expected_nodes,
        )
        return

    log.info(
        "EE cluster resilience: terminating one of %d nodes...\n", expected_nodes
    )

    original_instance_id = get_asg_instance_id(
        session, config.stack_name, resource_map, exclude_instance=tunnel_instance_id
    )
    log.info("  Original instance: %s\n", original_instance_id)

    with reporter.test("Terminate one cluster node") as ctx:
        try:
            terminate_instance(session, original_instance_id)
            ctx.pass_(f"Terminated {original_instance_id}")
        except Exception as exc:
            ctx.fail(f"Failed to terminate instance: {exc}")
            return

    with reporter.test("Wait for ASG replacement") as ctx:
        try:
            recovered = wait_for_cluster_recovery(
                session,
                config.stack_name,
                resource_map,
                terminated_instance=original_instance_id,
                expected_count=expected_nodes,
                timeout=replacement_timeout,
            )
            ctx.pass_(
                f"Cluster recovered to {len(recovered)} InService instances "
                f"(terminated {original_instance_id})"
            )
        except Exception as exc:
            ctx.fail(str(exc))
            return

    log.info("Waiting for Neo4j after cluster recovery...")
    if not wait_for_neo4j(config, timeout=300, interval=10):
        with reporter.test("Post-recovery Neo4j readiness") as ctx:
            ctx.fail("Neo4j did not become reachable within 300s after cluster recovery")
        return

    _check_cluster_overview(config, reporter, expected_nodes)


def run_resilience_tests(
    config: StackConfig,
    reporter: TestReporter,
    session: boto3.Session,
    replacement_timeout: int = 600,
    resource_map: dict[str, str] | None = None,
    tunnel_instance_id: str | None = None,
) -> None:
    """Orchestrate resilience tests: Raft cluster recovery (EE) or EBS persistence (CE)."""
    if config.edition == "ee":
        run_ee_resilience_tests(
            config, reporter, session, replacement_timeout, resource_map,
            tunnel_instance_id=tunnel_instance_id,
        )
        return

    test_run_id = uuid.uuid4().hex

    if resource_map is None:
        resource_map = get_stack_resources(session, config.stack_name)

    run_volume_checks(config, reporter, session, resource_map)

    if not _write_sentinel(config, reporter, test_run_id):
        return

    if not create_movies_dataset(config, reporter):
        return

    if not _terminate_and_wait(config, reporter, session, resource_map, replacement_timeout):
        return

    run_simple_tests(config, reporter)

    _verify_sentinel(config, reporter, test_run_id)
    verify_movies_dataset(config, reporter)

    _cleanup_sentinel(config, test_run_id)
    cleanup_movies_dataset(config)
