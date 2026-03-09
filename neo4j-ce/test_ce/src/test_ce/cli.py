"""CLI entry point for the Neo4j CE stack test suite."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from test_ce.config import load_config
from test_ce.movies_dataset import (
    cleanup_movies_dataset,
    create_movies_dataset,
    verify_movies_dataset,
)
from test_ce.neo4j_checks import run_simple_tests
from test_ce.neo4j_deep_checks import run_deep_neo4j_checks
from test_ce.reporting import TestReporter
from test_ce.resilience import run_resilience_tests
from test_ce.wait import wait_for_neo4j

log = logging.getLogger(__name__)


def _resolve_outputs_path(explicit: Path | None, stack: str | None) -> Path:
    """Return the path to the deployment outputs file.

    Resolution order:
    1. Explicit --outputs-file path
    2. --stack <name> -> ../.deploy/<name>.txt
    3. Most recently modified .txt in ../.deploy/
    """
    if explicit:
        return explicit

    deploy_dir = Path.cwd().parent / ".deploy"

    if stack:
        return deploy_dir / f"{stack}.txt"

    # Find newest .txt in .deploy/
    if deploy_dir.is_dir():
        txt_files = sorted(deploy_dir.glob("*.txt"), key=lambda p: p.stat().st_mtime, reverse=True)
        if txt_files:
            return txt_files[0]

    # No deployment found — return a path that will fail with a clear FileNotFoundError
    return deploy_dir / "no-deployment-found.txt"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Test a deployed Neo4j CE CloudFormation stack",
    )
    parser.add_argument(
        "--simple",
        action="store_true",
        help=(
            "Run only connectivity tests (HTTP, auth, Bolt, APOC). "
            "Default is full mode which also tests EBS persistence."
        ),
    )
    parser.add_argument(
        "--password",
        help="Override the password from the outputs file",
    )
    parser.add_argument(
        "--stack",
        help="Stack name — resolves to ../.deploy/<stack-name>.txt",
    )
    parser.add_argument(
        "--outputs-file",
        type=Path,
        help="Explicit path to outputs file (overrides --stack)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=600,
        help="Timeout in seconds for ASG replacement (default: 600)",
    )
    args = parser.parse_args()

    # Configure logging: plain messages to stdout, matching the bash script style
    logging.basicConfig(format="%(message)s", level=logging.INFO, stream=sys.stdout)

    outputs_path = _resolve_outputs_path(args.outputs_file, args.stack)

    try:
        config = load_config(outputs_path, args.password)
    except (FileNotFoundError, ValueError) as exc:
        log.error("ERROR: %s", exc)
        sys.exit(1)

    mode = "simple" if args.simple else "full"
    reporter = TestReporter()

    log.info("=== Neo4j CE Stack Tester ===")
    log.info("")
    log.info("  Stack:    %s", config.stack_name)
    log.info("  Host:     %s", config.host)
    log.info("  Mode:     %s", mode)
    log.info("")

    # Wait for initial readiness
    if not wait_for_neo4j(config, timeout=300, interval=10):
        log.info("")
        log.info("Troubleshooting:")
        log.info(
            "  aws cloudformation describe-stacks --stack-name %s --region %s",
            config.stack_name,
            config.region,
        )
        sys.exit(1)
    log.info("")

    # Run simple tests (always)
    run_simple_tests(config, reporter)

    # Deep Neo4j config checks (always — only needs Bolt)
    run_deep_neo4j_checks(config, reporter)

    if args.simple:
        # In simple mode, validate Cypher write/read with the Movies dataset
        # (in full mode, resilience tests handle this with persistence verification)
        if create_movies_dataset(config, reporter):
            verify_movies_dataset(config, reporter)
            cleanup_movies_dataset(config)
    else:
        # Full mode: infra checks, volume checks, Movies dataset persistence, instance replacement
        import boto3  # noqa: PLC0415 — only needed for full mode

        from test_ce.aws_helpers import get_stack_resources  # noqa: PLC0415
        from test_ce.infra_checks import run_infra_checks  # noqa: PLC0415

        session = boto3.Session(region_name=config.region)
        resource_map = get_stack_resources(session, config.stack_name)

        run_infra_checks(session, config, reporter, resource_map)
        run_resilience_tests(
            config, reporter, session,
            replacement_timeout=args.timeout,
            resource_map=resource_map,
        )

    # Print summary and exit
    exit_code = reporter.summary(
        stack_name=config.stack_name,
        endpoint=config.host,
    )
    sys.exit(exit_code)
