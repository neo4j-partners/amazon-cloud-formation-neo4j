"""Deeper Neo4j configuration validation: bindings, memory, data directory."""

from __future__ import annotations

import logging

from neo4j import RoutingControl

from test_neo4j.config import StackConfig
from test_neo4j.reporting import TestReporter

log = logging.getLogger(__name__)


def check_server_status(config: StackConfig, reporter: TestReporter) -> None:
    """Verify Neo4j reports the expected edition via dbms.components()."""
    expected = "enterprise" if config.edition == "ee" else "community"
    with reporter.test("Neo4j server status") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "CALL dbms.components() YIELD name, versions, edition "
                    "RETURN name, versions[0] AS version, edition",
                    routing_=RoutingControl.READ,
                )
                row = records[0]
                name = row["name"]
                version = row["version"]
                edition = row["edition"]

                if expected in edition.lower():
                    ctx.pass_(f"{name} {version} ({edition})")
                else:
                    ctx.fail(f"Expected {expected} edition, got: {edition}")
        except Exception as exc:
            ctx.fail(f"dbms.components() failed: {exc}")


def check_listen_address(config: StackConfig, reporter: TestReporter) -> None:
    """Verify server.default_listen_address is 0.0.0.0."""
    with reporter.test("Listen address") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "CALL dbms.listConfig('server.default_listen_address') "
                    "YIELD value RETURN value",
                    routing_=RoutingControl.READ,
                )
                value = records[0]["value"]
                if value == "0.0.0.0":
                    ctx.pass_("server.default_listen_address = 0.0.0.0")
                else:
                    ctx.fail(
                        f"server.default_listen_address = {value} (expected 0.0.0.0)"
                    )
        except Exception as exc:
            ctx.fail(f"Failed to query listen address: {exc}")


def check_advertised_address(config: StackConfig, reporter: TestReporter) -> None:
    """CE only: verify the advertised address matches the Elastic IP."""
    with reporter.test("Advertised address") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "CALL dbms.listConfig('server.default_advertised_address') "
                    "YIELD value RETURN value",
                    routing_=RoutingControl.READ,
                )
                value = records[0]["value"]
                if value == config.host:
                    ctx.pass_(
                        f"server.default_advertised_address = {value} "
                        f"(matches Elastic IP)"
                    )
                else:
                    ctx.fail(
                        f"server.default_advertised_address = {value} "
                        f"(expected {config.host})"
                    )
        except Exception as exc:
            ctx.fail(f"Failed to query advertised address: {exc}")


def check_memory_config(config: StackConfig, reporter: TestReporter) -> None:
    """Verify heap and page cache are configured (not default empty values)."""
    with reporter.test("Memory configuration") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "CALL dbms.listConfig() YIELD name, value "
                    "WHERE name IN ["
                    "  'server.memory.heap.max_size',"
                    "  'server.memory.pagecache.size'"
                    "] "
                    "RETURN name, value",
                    routing_=RoutingControl.READ,
                )
                settings = {r["name"]: r["value"] for r in records}
                heap = settings.get("server.memory.heap.max_size", "")
                pagecache = settings.get("server.memory.pagecache.size", "")

                if heap and pagecache:
                    ctx.pass_(f"heap.max_size={heap}, pagecache.size={pagecache}")
                else:
                    missing = []
                    if not heap:
                        missing.append("heap.max_size")
                    if not pagecache:
                        missing.append("pagecache.size")
                    ctx.fail(f"Memory not configured: {', '.join(missing)} is empty")
        except Exception as exc:
            ctx.fail(f"Failed to query memory config: {exc}")


def check_data_directory(config: StackConfig, reporter: TestReporter) -> None:
    """Verify server.directories.data is on the persistent EBS volume mount."""
    # CE mounts the EBS volume at /data and sets server.directories.data there.
    # EE uses the default Neo4j data directory (/var/lib/neo4j/data).
    expected = "/data" if config.edition == "ce" else "/var/lib/neo4j/data"
    with reporter.test("Data directory") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "CALL dbms.listConfig('server.directories.data') "
                    "YIELD value RETURN value",
                    routing_=RoutingControl.READ,
                )
                value = records[0]["value"]
                if value == expected:
                    ctx.pass_(f"server.directories.data = {value}")
                else:
                    ctx.fail(
                        f"server.directories.data = {value} (expected {expected})"
                    )
        except Exception as exc:
            ctx.fail(f"Failed to query data directory: {exc}")


def run_deep_neo4j_checks(config: StackConfig, reporter: TestReporter) -> None:
    """Run all deeper Neo4j configuration validation tests."""
    check_server_status(config, reporter)
    check_listen_address(config, reporter)
    if config.edition == "ce":
        check_advertised_address(config, reporter)
    check_memory_config(config, reporter)
    check_data_directory(config, reporter)
