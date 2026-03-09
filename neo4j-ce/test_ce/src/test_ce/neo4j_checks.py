"""Simple connectivity tests: HTTP API, authentication, Bolt, and APOC."""

from __future__ import annotations

import logging

import requests

from test_ce.config import StackConfig
from test_ce.reporting import TestReporter

log = logging.getLogger(__name__)


def check_http_api(config: StackConfig, reporter: TestReporter) -> None:
    """GET the discovery endpoint and verify neo4j_version is present."""
    with reporter.test("HTTP API") as ctx:
        try:
            resp = requests.get(config.browser_url, timeout=10)
            resp.raise_for_status()
            data = resp.json()
        except requests.RequestException as exc:
            ctx.fail(f"HTTP request failed: {exc}")
            return
        except ValueError as exc:
            ctx.fail(f"Invalid JSON response: {exc}")
            return

        version = data.get("neo4j_version")
        if version:
            ctx.pass_(f"HTTP endpoint returned neo4j_version: {version}")
        else:
            ctx.fail(f"Response does not contain neo4j_version: {data}")


def check_auth(config: StackConfig, reporter: TestReporter) -> None:
    """POST a Cypher statement with Basic Auth and check for HTTP 200."""
    with reporter.test("Authentication (HTTP)") as ctx:
        try:
            resp = requests.post(
                f"{config.browser_url}/db/neo4j/tx/commit",
                json={"statements": [{"statement": "RETURN 1"}]},
                auth=(config.username, config.password),
                timeout=10,
            )
        except requests.RequestException as exc:
            ctx.fail(f"HTTP request failed: {exc}")
            return

        if resp.status_code == 200:
            ctx.pass_("Authentication successful (HTTP 200)")
        elif resp.status_code == 401:
            ctx.fail("Authentication failed (HTTP 401). Check the password.")
        else:
            ctx.fail(f"Unexpected HTTP status: {resp.status_code}")


def check_bolt(config: StackConfig, reporter: TestReporter) -> None:
    """Connect via the Bolt protocol and execute RETURN 1."""
    with reporter.test("Bolt connectivity") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query("RETURN 1 AS result")
                value = records[0]["result"]
                if value == 1:
                    ctx.pass_(f"Bolt connected, Cypher returned: {value}")
                else:
                    ctx.fail(f"Unexpected result: {value}")
        except Exception as exc:
            ctx.fail(f"Bolt connection failed: {exc}")


def check_apoc(config: StackConfig, reporter: TestReporter) -> None:
    """Verify apoc.version() is callable (skipped if APOC not installed)."""
    if not config.install_apoc:
        log.info("--- Skipping APOC test (install_apoc=%s) ---\n", config.install_apoc)
        return

    with reporter.test("APOC plugin") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "RETURN apoc.version() AS version"
                )
                version = records[0]["version"]
                ctx.pass_(f"APOC is available, version: {version}")
        except Exception as exc:
            ctx.fail(f"APOC query failed: {exc}")


def run_simple_tests(config: StackConfig, reporter: TestReporter) -> None:
    """Run all simple connectivity tests in order."""
    check_http_api(config, reporter)
    check_auth(config, reporter)
    check_bolt(config, reporter)
    check_apoc(config, reporter)
