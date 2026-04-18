"""CLI entry point for the Neo4j stack test suite."""

from __future__ import annotations

import argparse
import contextlib
import logging
import sys
from pathlib import Path

from test_neo4j.config import LOCAL_BOLT_PORT, LOCAL_HTTP_PORT, load_config
from test_neo4j.movies_dataset import (
    cleanup_movies_dataset,
    create_movies_dataset,
    verify_movies_dataset,
)
from test_neo4j.neo4j_checks import run_simple_tests
from test_neo4j.neo4j_deep_checks import run_deep_neo4j_checks
from test_neo4j.reporting import TestReporter
from test_neo4j.resilience import run_resilience_tests
from test_neo4j.wait import wait_for_neo4j

log = logging.getLogger(__name__)

# Repo root: test_neo4j/src/test_neo4j/cli.py -> up 3 levels -> test_neo4j/ -> up 1 -> repo root
_REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent


def _deploy_dir(edition: str) -> Path:
    return _REPO_ROOT / f"neo4j-{edition}" / ".deploy"


def _resolve_outputs_path(
    explicit: Path | None,
    stack: str | None,
    edition: str,
) -> Path:
    """Return the path to the deployment outputs file.

    Resolution order:
    1. Explicit --outputs-file path
    2. --stack <name> -> neo4j-<edition>/.deploy/<name>.txt
    3. Most recently modified .txt in neo4j-<edition>/.deploy/
    """
    if explicit:
        return explicit

    deploy_dir = _deploy_dir(edition)

    if stack:
        return deploy_dir / f"{stack}.txt"

    if deploy_dir.is_dir():
        txt_files = sorted(
            deploy_dir.glob("*.txt"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if txt_files:
            return txt_files[0]

    return deploy_dir / "no-deployment-found.txt"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Test a deployed Neo4j CloudFormation stack",
    )
    parser.add_argument(
        "--edition",
        required=True,
        choices=["ce", "ee"],
        help="Stack edition: ce (Community) or ee (Enterprise)",
    )
    parser.add_argument(
        "--simple",
        action="store_true",
        help=(
            "Run only connectivity tests (HTTP, auth, Bolt, APOC). "
            "Default is full mode which also tests EBS persistence (CE). "
            "EE cluster resilience tests are not yet implemented."
        ),
    )
    parser.add_argument(
        "--password",
        help="Override the password from the outputs file",
    )
    parser.add_argument(
        "--stack",
        help="Stack name — resolves to neo4j-<edition>/.deploy/<stack-name>.txt",
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
    parser.add_argument(
        "--infra-security",
        action="store_true",
        help=(
            "Run network and instance security checks: external SG CIDR, "
            "port 5005 absence, internal SG self-reference, IMDSv2 enforcement, "
            "and JDWP absence in neo4j.conf (via SSM)."
        ),
    )
    parser.add_argument(
        "--run-extended-ee-checks",
        action="store_true",
        help=(
            "Run Private-mode EE infrastructure checks: NLB scheme, instance public-IP "
            "absence, private subnet placement, VPC endpoints, endpoint SG source, "
            "NAT Gateway count, and VPC DNS settings. "
            "Skipped automatically for CE stacks or Public-mode deployments."
        ),
    )
    args = parser.parse_args()

    logging.basicConfig(format="%(message)s", level=logging.INFO, stream=sys.stdout)

    outputs_path = _resolve_outputs_path(args.outputs_file, args.stack, args.edition)

    try:
        config = load_config(outputs_path, args.edition, args.password)
    except (FileNotFoundError, ValueError) as exc:
        log.error("ERROR: %s", exc)
        sys.exit(1)

    mode = "simple" if args.simple else "full"
    if args.infra_security:
        mode += "+infra-security"
    if args.run_extended_ee_checks:
        mode += "+extended-ee-checks"
    reporter = TestReporter()

    log.info("=== Neo4j %s Stack Tester ===", args.edition.upper())
    log.info("")
    log.info("  Stack:    %s", config.stack_name)
    log.info("  Host:     %s", config.host)
    log.info("  Edition:  %s", config.edition.upper())
    log.info("  Mode:     %s", mode)
    log.info("  Deploy:   %s", config.deployment_mode)
    log.info("")

    # Initialise AWS session early if Private mode (needed for SSM tunnels) or
    # if the test mode requires infra checks.
    session = None
    resource_map = None
    need_aws = (
        config.deployment_mode == "Private"
        or not args.simple
        or args.infra_security
        or args.run_extended_ee_checks
    )

    if need_aws:
        import boto3  # noqa: PLC0415

        from test_neo4j.aws_helpers import (  # noqa: PLC0415
            get_asg_instance_id,
            get_stack_resources,
            ssm_port_forward,
        )

        session = boto3.Session(region_name=config.region)
        resource_map = get_stack_resources(session, config.stack_name)

    fwd_stack = contextlib.ExitStack()

    if config.deployment_mode == "Private":
        instance_id = get_asg_instance_id(session, config.stack_name, resource_map)
        log.info("  SSM target:   %s", instance_id)
        log.info("  NLB:          %s", config.nlb_dns)
        log.info("  Local HTTP:   localhost:%d -> %s:7474", LOCAL_HTTP_PORT, config.nlb_dns)
        log.info("  Local Bolt:   localhost:%d -> %s:7687", LOCAL_BOLT_PORT, config.nlb_dns)
        log.info("")
        log.info("Opening SSM tunnels...")
        fwd_stack.enter_context(
            ssm_port_forward(instance_id, config.nlb_dns, 7474, LOCAL_HTTP_PORT, config.region)
        )
        fwd_stack.enter_context(
            ssm_port_forward(instance_id, config.nlb_dns, 7687, LOCAL_BOLT_PORT, config.region)
        )

    with fwd_stack:
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

        run_simple_tests(config, reporter)
        run_deep_neo4j_checks(config, reporter)

        if create_movies_dataset(config, reporter):
            verify_movies_dataset(config, reporter)
            cleanup_movies_dataset(config)

        if not args.simple:
            from test_neo4j.infra_checks import run_infra_checks  # noqa: PLC0415

            run_infra_checks(session, config, reporter, resource_map)
            run_resilience_tests(
                config, reporter, session,
                replacement_timeout=args.timeout,
                resource_map=resource_map,
            )

        if args.infra_security:
            from test_neo4j.infra_checks import run_network_security_checks  # noqa: PLC0415

            run_network_security_checks(session, config, reporter, resource_map)

        if args.run_extended_ee_checks:
            from test_neo4j.infra_checks import run_private_mode_checks  # noqa: PLC0415

            if config.edition == "ee":
                run_private_mode_checks(session, config, reporter, resource_map)
            else:
                log.info(
                    "--run-extended-ee-checks is EE-only — skipping for CE.\n"
                )

    exit_code = reporter.summary(
        stack_name=config.stack_name,
        endpoint=config.host,
    )
    sys.exit(exit_code)
