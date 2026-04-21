"""Cluster quorum checks and preflight for EE Private clusters."""

from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING

from validate_private.runner import run_cypher_on_bastion

if TYPE_CHECKING:
    from validate_private.config import StackConfig
    from validate_private.reporting import TestReporter

log = logging.getLogger(__name__)


def preflight_healthy(config: "StackConfig", expected_nodes: int = 3) -> tuple[bool, str]:
    """Return (True, detail) if all expected nodes are Available, (False, reason) otherwise."""
    try:
        rows = run_cypher_on_bastion(config, "SHOW SERVERS", database="system")
        actual = len(rows)
        unhealthy = [
            r.get("name", r.get("serverId", "?"))
            for r in rows
            if r.get("health") != "Available" or r.get("state") != "Enabled"
        ]
        if actual != expected_nodes:
            return False, f"expected {expected_nodes} nodes, found {actual}"
        if unhealthy:
            return False, f"unhealthy nodes: {unhealthy}"
        return True, f"{actual} nodes all Available"
    except Exception as exc:
        return False, str(exc)


def check_quorum(
    config: "StackConfig",
    reporter: "TestReporter",
    expected_nodes: int,
    label: str = "Cluster quorum",
    expected_writer_uuid: str | None = None,
) -> bool:
    """Verify cluster quorum: expected node count, all healthy, exactly 1 writer.

    Records to reporter and returns True on pass, False on any failure.
    When expected_writer_uuid is provided, also verifies the current writer UUID
    matches — used by run_rolling to detect unexpected re-elections mid-test.
    """
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

        if expected_writer_uuid is not None and writer_count == 1:
            try:
                db_rows = run_cypher_on_bastion(
                    config,
                    "SHOW DATABASE neo4j YIELD serverID, writer WHERE writer = true",
                    database="system",
                )
                actual_writer = db_rows[0].get("serverID") if db_rows else None
                if actual_writer != expected_writer_uuid:
                    issues.append(
                        f"unexpected re-election: writer changed from "
                        f"{expected_writer_uuid[:8]}… to "
                        f"{actual_writer[:8] + '…' if actual_writer else 'unknown'}"
                    )
            except Exception as exc:
                issues.append(f"writer UUID check failed: {exc}")

        if issues:
            reporter.record(label, False, "Quorum check failed: " + "; ".join(issues), time.monotonic() - start)
            return False
        reporter.record(
            label, True,
            f"{actual_count} nodes (1 writer, {reader_count} reader(s))",
            time.monotonic() - start,
        )
        return True
    except Exception as exc:
        reporter.record(label, False, str(exc), time.monotonic() - start)
        return False
