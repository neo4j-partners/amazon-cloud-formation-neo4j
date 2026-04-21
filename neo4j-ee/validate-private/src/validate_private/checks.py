"""Validation checks run against the Neo4j cluster via the operator bastion."""

from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING

from validate_private.runner import Neo4jQueryError, run_cypher_on_bastion

if TYPE_CHECKING:
    from validate_private.config import StackConfig
    from validate_private.reporting import TestReporter

log = logging.getLogger(__name__)


def _run(config: "StackConfig", reporter: "TestReporter", name: str, cypher: str, check_fn) -> None:
    log.info("")
    log.info("--- %s ---", name)
    start = time.monotonic()
    try:
        rows = run_cypher_on_bastion(config, cypher)
        passed, detail = check_fn(rows)
    except Neo4jQueryError as exc:
        passed, detail = False, str(exc)
    except Exception as exc:
        passed, detail = False, f"ERROR: {exc}"
    reporter.record(name, passed, detail, time.monotonic() - start)


def check_bolt(config: "StackConfig", reporter: "TestReporter") -> None:
    def _check(rows):
        val = rows[0]["result"] if rows else None
        return val == 1, f"Bolt connected via bastion, Cypher returned: {val}"

    _run(config, reporter, "Bolt connectivity", "RETURN 1 AS result", _check)


def check_server_status(config: "StackConfig", reporter: "TestReporter") -> None:
    cypher = "CALL dbms.components() YIELD name, versions, edition RETURN name, versions[0] AS version, edition"

    def _check(rows):
        if not rows:
            return False, "No rows returned"
        r = rows[0]
        edition = r.get("edition", "")
        version = r.get("version", "unknown")
        passed = edition == "enterprise"
        detail = f"Neo4j Kernel {version} ({edition})"
        return passed, detail

    _run(config, reporter, "Neo4j server status", cypher, _check)


def check_listen_address(config: "StackConfig", reporter: "TestReporter") -> None:
    cypher = "CALL dbms.listConfig('server.default_listen_address') YIELD name, value RETURN value"

    def _check(rows):
        val = rows[0]["value"] if rows else ""
        passed = val == "0.0.0.0"
        return passed, f"server.default_listen_address = {val!r}"

    _run(config, reporter, "Listen address", cypher, _check)


def check_memory_config(config: "StackConfig", reporter: "TestReporter") -> None:
    cypher = (
        "CALL dbms.listConfig() YIELD name, value "
        "WHERE name IN ['server.memory.heap.initial_size', 'server.memory.heap.max_size', "
        "'server.memory.pagecache.size'] "
        "RETURN name, value ORDER BY name"
    )

    def _check(rows):
        if not rows:
            return False, "No memory config rows returned"
        parts = [f"{r['name']}={r['value']}" for r in rows]
        return True, ", ".join(parts)

    _run(config, reporter, "Memory configuration", cypher, _check)


def check_data_directory(config: "StackConfig", reporter: "TestReporter") -> None:
    cypher = "CALL dbms.listConfig('server.directories.data') YIELD name, value RETURN value"

    def _check(rows):
        val = rows[0]["value"] if rows else ""
        passed = val == "/var/lib/neo4j/data"
        return passed, f"data directory = {val!r}"

    _run(config, reporter, "Data directory", cypher, _check)


def check_apoc(config: "StackConfig", reporter: "TestReporter") -> None:
    if not config.install_apoc:
        return

    cypher = "CALL apoc.help('apoc') YIELD name RETURN count(name) AS procedures"

    def _check(rows):
        count = rows[0]["procedures"] if rows else 0
        return count > 0, f"APOC loaded, {count} procedures available"

    _run(config, reporter, "APOC plugin", cypher, _check)


def check_cluster_roles(config: "StackConfig", reporter: "TestReporter") -> None:
    """Verify SHOW DATABASE returns per-node serverId with exactly one writer."""
    start = time.monotonic()
    try:
        rows = run_cypher_on_bastion(
            config,
            "SHOW DATABASE neo4j YIELD serverID, writer",
            database="system",
        )
    except Exception as exc:
        reporter.record("Cluster roles (serverId)", False, str(exc), time.monotonic() - start)
        return

    if not rows:
        reporter.record(
            "Cluster roles (serverId)", False,
            "SHOW DATABASE returned no rows — serverId column may not be supported on this version",
            time.monotonic() - start,
        )
        return

    server_ids = [r.get("serverID") for r in rows]
    missing = [s for s in server_ids if not s]
    writers = [r for r in rows if r.get("writer")]
    duplicates = len(server_ids) != len(set(server_ids))

    issues = []
    if missing:
        issues.append(f"{len(missing)} row(s) with null/missing serverId")
    if duplicates:
        issues.append("duplicate serverIds — address-join collision would still occur")
    if len(writers) != 1:
        issues.append(f"expected exactly 1 writer, got {len(writers)}")

    if issues:
        reporter.record(
            "Cluster roles (serverId)", False,
            "; ".join(issues),
            time.monotonic() - start,
        )
    else:
        followers = len(rows) - 1
        reporter.record(
            "Cluster roles (serverId)", True,
            f"{len(rows)} node(s): 1 writer, {followers} follower(s); all serverIds distinct",
            time.monotonic() - start,
        )


_ASG_LOGICAL_IDS = ("Neo4jNode1ASG", "Neo4jNode2ASG", "Neo4jNode3ASG")


def run_server_id_check(config: "StackConfig", reporter: "TestReporter") -> None:
    """Verify each cluster node's server_id binary file decodes to the UUID SHOW SERVERS reports."""
    import boto3

    from botocore.config import Config as BotocoreConfig
    from validate_private.aws_helpers import asg_instances, stack_resources
    from validate_private.server_ids import read_server_uuid

    retry_cfg = BotocoreConfig(retries={"mode": "standard"})
    cfn = boto3.client("cloudformation", region_name=config.region, config=retry_cfg)
    asg = boto3.client("autoscaling", region_name=config.region, config=retry_cfg)
    ssm = boto3.client("ssm", region_name=config.region, config=retry_cfg)

    log.info("")
    log.info("=== Server ID file check ===")
    log.info("")

    # Discover running instances via CFN stack → ASG → EC2.
    start = time.monotonic()
    try:
        resources = stack_resources(cfn, config.stack_name)
    except Exception as exc:
        reporter.record("Discover cluster instances", False, str(exc), time.monotonic() - start)
        return

    instance_ids: list[str] = []
    for logical in _ASG_LOGICAL_IDS:
        asg_name = resources.get(logical)
        if asg_name:
            instance_ids.extend(asg_instances(asg, asg_name))

    if not instance_ids:
        reporter.record(
            "Discover cluster instances", False,
            f"No running instances found for ASGs {_ASG_LOGICAL_IDS} in stack {config.stack_name}",
            time.monotonic() - start,
        )
        return

    reporter.record(
        "Discover cluster instances", True,
        f"Found {len(instance_ids)} instance(s): {', '.join(instance_ids)}",
        time.monotonic() - start,
    )

    # Get the authoritative UUIDs from SHOW SERVERS via the bastion.
    start = time.monotonic()
    try:
        server_rows = run_cypher_on_bastion(config, "SHOW SERVERS YIELD name", database="system")
        authoritative_uuids = {r["name"] for r in server_rows if r.get("name")}
    except Exception as exc:
        reporter.record("SHOW SERVERS (authoritative UUIDs)", False, str(exc), time.monotonic() - start)
        return

    reporter.record(
        "SHOW SERVERS (authoritative UUIDs)", True,
        f"{len(authoritative_uuids)} UUID(s): {', '.join(sorted(authoritative_uuids))}",
        time.monotonic() - start,
    )

    # Decode the binary server_id file on each instance and compare.
    for iid in instance_ids:
        start = time.monotonic()
        decoded = read_server_uuid(ssm, iid)
        if decoded is None:
            reporter.record(
                f"server_id decode ({iid})", False,
                "SSM command failed — check instance SSM connectivity",
                time.monotonic() - start,
            )
            continue
        match = decoded in authoritative_uuids
        reporter.record(
            f"server_id decode ({iid})", match,
            f"decoded={decoded!r} {'in' if match else 'NOT IN'} SHOW SERVERS",
            time.monotonic() - start,
        )

    log.info("")


def run_checks(config: "StackConfig", reporter: "TestReporter") -> None:
    check_bolt(config, reporter)
    check_server_status(config, reporter)
    check_listen_address(config, reporter)
    check_memory_config(config, reporter)
    check_data_directory(config, reporter)
    check_apoc(config, reporter)
    check_cluster_roles(config, reporter)
