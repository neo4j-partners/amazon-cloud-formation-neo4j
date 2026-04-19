"""Polling / readiness helpers shared across simple and resilience tests."""

from __future__ import annotations

import logging
import time

import requests

from test_neo4j.config import StackConfig

log = logging.getLogger(__name__)


def wait_for_neo4j(config: StackConfig, timeout: int = 300, interval: int = 10) -> bool:
    """Poll the HTTP endpoint until Neo4j responds with 200, or timeout."""
    log.info("Waiting for Neo4j to become reachable (timeout: %ds)...", timeout)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            resp = requests.get(config.browser_url, timeout=5, headers={"Connection": "close"})
            if resp.status_code == 200:
                elapsed = timeout - (deadline - time.monotonic())
                log.info("  Neo4j HTTP endpoint is responding (%.0fs elapsed).", elapsed)
                return True
        except (requests.ConnectionError, requests.Timeout):
            pass

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        log.info("  Not ready yet... retrying in %ds", interval)
        time.sleep(min(interval, remaining))

    log.error("Neo4j did not become reachable within %ds.", timeout)
    return False
