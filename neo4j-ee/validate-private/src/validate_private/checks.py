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


def run_checks(config: "StackConfig", reporter: "TestReporter") -> None:
    check_bolt(config, reporter)
    check_server_status(config, reporter)
    check_listen_address(config, reporter)
    check_memory_config(config, reporter)
    check_data_directory(config, reporter)
    check_apoc(config, reporter)
