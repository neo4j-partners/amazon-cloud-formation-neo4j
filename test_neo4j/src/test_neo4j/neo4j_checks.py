"""Simple connectivity tests: HTTP API, authentication, Bolt, APOC, and
optional Bloom/GDS Enterprise licence assertions (gated on the deploy outputs
file recording a licence secret ID)."""

from __future__ import annotations

import logging

import requests

from test_neo4j.config import StackConfig
from test_neo4j.reporting import TestReporter

log = logging.getLogger(__name__)


def check_http_api(config: StackConfig, reporter: TestReporter) -> None:
    """GET the discovery endpoint and verify neo4j_version is present."""
    with reporter.test("HTTP API") as ctx:
        try:
            resp = requests.get(config.browser_url, timeout=10, headers={"Connection": "close"})
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
                headers={"Connection": "close"},
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


def check_bloom_license(config: StackConfig, reporter: TestReporter) -> None:
    """Assert Bloom reports a valid licence.

    bloom.checkLicenseCompliance() returns status="valid" when the licence
    file is present at the path configured by dbms.bloom.license_file and
    the JWT validates. Without a licence it reports "missing" — gds.version()
    style smoke tests would not catch this regression.
    """
    if not config.bloom_licensed:
        return
    with reporter.test("Bloom Enterprise licence") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "CALL bloom.checkLicenseCompliance()"
                )
                status = records[0]["status"] if records else None
                if status == "valid":
                    ctx.pass_(f"bloom.checkLicenseCompliance status={status}")
                else:
                    ctx.fail(f"bloom.checkLicenseCompliance status={status!r}")
        except Exception as exc:
            ctx.fail(f"bloom.checkLicenseCompliance failed: {exc}")


def check_gds_license(config: StackConfig, reporter: TestReporter) -> None:
    """Assert GDS is in Enterprise mode.

    gds.version() returns a version in Community mode too, so two independent
    checks are required: gds.isLicensed() must return TRUE, and the gdsEdition
    sysInfo key must report "Licensed".
    """
    if not config.gds_licensed:
        return
    with reporter.test("GDS Enterprise licence") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "RETURN gds.isLicensed() AS isLicensed"
                )
                is_licensed = records[0]["isLicensed"] if records else None
                if is_licensed is not True:
                    ctx.fail(f"gds.isLicensed() returned {is_licensed!r}")
                    return
                records, _, _ = driver.execute_query(
                    "CALL gds.debug.sysInfo() YIELD key, value "
                    "WHERE key = 'gdsEdition' RETURN value AS edition"
                )
                edition = records[0]["edition"] if records else None
                if edition == "Licensed":
                    ctx.pass_("gds.isLicensed=TRUE, gdsEdition=Licensed")
                else:
                    ctx.fail(f"gdsEdition={edition!r} (expected 'Licensed')")
        except Exception as exc:
            ctx.fail(f"GDS licence query failed: {exc}")


def run_simple_tests(config: StackConfig, reporter: TestReporter) -> None:
    """Run all simple connectivity tests in order."""
    check_http_api(config, reporter)
    check_auth(config, reporter)
    check_bolt(config, reporter)
    check_apoc(config, reporter)
    check_bloom_license(config, reporter)
    check_gds_license(config, reporter)
