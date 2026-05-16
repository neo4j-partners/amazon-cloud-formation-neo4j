"""Validation checks run against the Neo4j cluster via the operator bastion."""

from __future__ import annotations

import logging
import re
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


def check_gds(config: "StackConfig", reporter: "TestReporter") -> None:
    if not config.install_gds:
        return

    cypher = "RETURN gds.version() AS version"

    def _check(rows):
        version = rows[0]["version"] if rows else None
        return bool(version), f"GDS {version}" if version else "no result"

    _run(config, reporter, "GDS plugin", cypher, _check)


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


def _java_major(version_line: str) -> int | None:
    """Return the Java major version from a java -version first line."""
    match = re.search(r'version "([^"]+)"', version_line)
    if not match:
        return None
    version = match.group(1)
    if version.startswith("1."):
        parts = version.split(".")
        return int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else None
    major = version.split(".", 1)[0]
    return int(major) if major.isdigit() else None


def _parse_key_value_lines(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


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


def run_blocklist_check(config: "StackConfig", reporter: "TestReporter") -> None:
    """Assert internal.dbms.cypher_ip_blocklist is present and non-empty on
    every node's effective neo4j.conf (NFR-2, ties to the G3 conf-key audit).

    Presence-only by design (AD-2): a non-empty value passes; CIDR content is
    owned by the build-time contract tests, not this runtime audit.
    """
    import boto3

    from botocore.config import Config as BotocoreConfig
    from validate_private.aws_helpers import asg_instances, stack_resources
    from validate_private.runner import run_shell_on_instance

    retry_cfg = BotocoreConfig(retries={"mode": "standard"})
    cfn = boto3.client("cloudformation", region_name=config.region, config=retry_cfg)
    asg = boto3.client("autoscaling", region_name=config.region, config=retry_cfg)
    ssm = boto3.client("ssm", region_name=config.region, config=retry_cfg)

    log.info("")
    log.info("=== Cypher IP blocklist invariant (per node) ===")

    start = time.monotonic()
    try:
        resources = stack_resources(cfn, config.stack_name)
    except Exception as exc:
        reporter.record("Blocklist: discover instances", False, str(exc), time.monotonic() - start)
        return

    instance_ids: list[str] = []
    for logical in _ASG_LOGICAL_IDS:
        asg_name = resources.get(logical)
        if asg_name:
            instance_ids.extend(asg_instances(asg, asg_name))

    if not instance_ids:
        reporter.record(
            "Blocklist: discover instances", False,
            f"No running instances found for ASGs {_ASG_LOGICAL_IDS} in stack {config.stack_name}",
            time.monotonic() - start,
        )
        return

    extract = (
        "awk -F= '/^internal\\.dbms\\.cypher_ip_blocklist=/ "
        "{sub(/^[^=]*=/, \"\"); print; exit}' /etc/neo4j/neo4j.conf"
    )
    for iid in instance_ids:
        start = time.monotonic()
        ok, stdout, stderr = run_shell_on_instance(ssm, iid, extract)
        value = stdout.strip()
        passed = ok and bool(value)
        if passed:
            detail = f"present and non-empty ({value})"
        elif not ok:
            detail = f"SSM command failed: {stderr.strip() or 'unknown error'}"
        else:
            detail = "internal.dbms.cypher_ip_blocklist absent or empty"
        reporter.record(
            f"Blocklist active ({iid})", passed, detail, time.monotonic() - start
        )

    log.info("")


def run_version_inventory(
    config: "StackConfig",
    reporter: "TestReporter",
    *,
    expected_neo4j_version: str | None = None,
    min_java_major: int | None = None,
) -> None:
    """Record and optionally assert the deployed Neo4j and Java versions."""
    import boto3

    from botocore.config import Config as BotocoreConfig
    from validate_private.aws_helpers import asg_instances, stack_resources
    from validate_private.runner import run_shell_on_instance

    log.info("")
    log.info("=== Release version inventory ===")

    start = time.monotonic()
    try:
        rows = run_cypher_on_bastion(
            config,
            "CALL dbms.components() YIELD name, versions, edition "
            "RETURN name, versions[0] AS version, edition",
        )
        if not rows:
            reporter.record("Neo4j component version", False, "No rows returned", time.monotonic() - start)
        else:
            row = rows[0]
            version = row.get("version", "unknown")
            edition = row.get("edition", "unknown")
            passed = edition == "enterprise"
            if expected_neo4j_version:
                passed = passed and version == expected_neo4j_version
            detail = f"Neo4j Kernel {version} ({edition})"
            if expected_neo4j_version:
                detail += f"; expected {expected_neo4j_version}"
            reporter.record("Neo4j component version", passed, detail, time.monotonic() - start)
    except Exception as exc:
        reporter.record("Neo4j component version", False, str(exc), time.monotonic() - start)

    retry_cfg = BotocoreConfig(retries={"mode": "standard"})
    cfn = boto3.client("cloudformation", region_name=config.region, config=retry_cfg)
    asg = boto3.client("autoscaling", region_name=config.region, config=retry_cfg)
    ssm = boto3.client("ssm", region_name=config.region, config=retry_cfg)

    start = time.monotonic()
    try:
        resources = stack_resources(cfn, config.stack_name)
    except Exception as exc:
        reporter.record("Version inventory: discover instances", False, str(exc), time.monotonic() - start)
        return

    instance_ids: list[str] = []
    for logical in _ASG_LOGICAL_IDS:
        asg_name = resources.get(logical)
        if asg_name:
            instance_ids.extend(asg_instances(asg, asg_name))

    if not instance_ids:
        reporter.record(
            "Version inventory: discover instances",
            False,
            f"No running instances found for ASGs {_ASG_LOGICAL_IDS} in stack {config.stack_name}",
            time.monotonic() - start,
        )
        return

    reporter.record(
        "Version inventory: discover instances",
        True,
        f"Found {len(instance_ids)} instance(s): {', '.join(instance_ids)}",
        time.monotonic() - start,
    )

    inventory_cmd = "\n".join([
        "printf 'neo4j_rpm_version=%s\\n' \"$(rpm -q --qf '%{VERSION}' neo4j-enterprise 2>/dev/null || true)\"",
        "printf 'neo4j_rpm_release=%s\\n' \"$(rpm -q --qf '%{RELEASE}' neo4j-enterprise 2>/dev/null || true)\"",
        "printf 'java_version=%s\\n' \"$(java -version 2>&1 | head -n 1)\"",
        "printf 'cypher_default=%s\\n' \"$(awk -F= '/^db.query.default_language=/ {sub(/^[^=]*=/, \"\"); print; exit}' /etc/neo4j/neo4j.conf)\"",
    ])

    for iid in instance_ids:
        start = time.monotonic()
        ok, stdout, stderr = run_shell_on_instance(ssm, iid, inventory_cmd)
        if not ok:
            reporter.record(
                f"Version inventory ({iid})",
                False,
                f"SSM command failed: {stderr.strip() or 'unknown error'}",
                time.monotonic() - start,
            )
            continue

        values = _parse_key_value_lines(stdout)
        rpm_version = values.get("neo4j_rpm_version", "")
        java_line = values.get("java_version", "")
        cypher_default = values.get("cypher_default", "")

        issues = []
        if not rpm_version:
            issues.append("neo4j-enterprise RPM version unavailable")
        if expected_neo4j_version and rpm_version != expected_neo4j_version:
            issues.append(f"rpm version {rpm_version!r} != expected {expected_neo4j_version!r}")
        java_major = _java_major(java_line)
        if java_major is None:
            issues.append(f"could not parse Java major from {java_line!r}")
        elif min_java_major is not None and java_major < min_java_major:
            issues.append(f"Java major {java_major} < required {min_java_major}")

        detail = (
            f"rpm={rpm_version}-{values.get('neo4j_rpm_release', '')}; "
            f"java={java_line or 'unknown'}; "
            f"db.query.default_language={cypher_default or 'unset'}"
        )
        if issues:
            detail = "; ".join(issues) + f"; {detail}"
        reporter.record(f"Version inventory ({iid})", not issues, detail, time.monotonic() - start)

    log.info("")


def run_release_gate(
    config: "StackConfig",
    reporter: "TestReporter",
    *,
    expected_neo4j_version: str | None = None,
    min_java_major: int | None = None,
) -> None:
    """Run the deploy-time release checks for a Private EE stack."""
    run_checks(config, reporter)
    run_version_inventory(
        config,
        reporter,
        expected_neo4j_version=expected_neo4j_version,
        min_java_major=min_java_major,
    )


def run_checks(config: "StackConfig", reporter: "TestReporter") -> None:
    check_bolt(config, reporter)
    check_server_status(config, reporter)
    check_listen_address(config, reporter)
    check_memory_config(config, reporter)
    check_data_directory(config, reporter)
    check_apoc(config, reporter)
    check_gds(config, reporter)
    check_cluster_roles(config, reporter)
    run_blocklist_check(config, reporter)
