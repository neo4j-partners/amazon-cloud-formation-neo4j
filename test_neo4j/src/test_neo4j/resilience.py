"""EBS persistence resilience tests: write sentinel, kill instance, verify data survives.

CE only. EE cluster resilience tests are deferred.
"""

from __future__ import annotations

import logging
import uuid
from typing import TYPE_CHECKING

from test_neo4j.aws_helpers import (
    get_asg_instance_id,
    get_stack_resources,
    terminate_instance,
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


def run_resilience_tests(
    config: StackConfig,
    reporter: TestReporter,
    session: boto3.Session,
    replacement_timeout: int = 600,
    resource_map: dict[str, str] | None = None,
) -> None:
    """Orchestrate EBS persistence tests. CE only — EE cluster resilience is deferred."""
    if config.edition == "ee":
        log.info("EE cluster resilience tests are not yet implemented — skipping.\n")
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
