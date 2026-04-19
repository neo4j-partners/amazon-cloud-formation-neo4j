"""CLI entry point: uv run validate-private"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from validate_private.checks import run_checks
from validate_private.config import load_config
from validate_private.reporting import TestReporter

log = logging.getLogger(__name__)

# validate-private/src/validate_private/cli.py -> up 4 levels -> neo4j-ee/
_NEO4J_EE_DIR = Path(__file__).resolve().parent.parent.parent.parent
_DEPLOY_DIR = _NEO4J_EE_DIR / ".deploy"


def _resolve_outputs_path(explicit: Path | None, stack: str | None) -> Path:
    if explicit:
        return explicit
    if stack:
        return _DEPLOY_DIR / f"{stack}.txt"
    if _DEPLOY_DIR.is_dir():
        txt_files = sorted(
            _DEPLOY_DIR.glob("*.txt"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        if txt_files:
            return txt_files[0]
    raise FileNotFoundError(
        f"No deployment found in {_DEPLOY_DIR}. "
        "Run deploy.sh first, or pass --stack <name>."
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate a deployed EE Private Neo4j stack via the operator bastion"
    )
    parser.add_argument(
        "--stack",
        help="Stack name — resolves to neo4j-ee/.deploy/<name>.txt",
    )
    parser.add_argument(
        "--outputs-file",
        type=Path,
        help="Explicit path to outputs file (overrides --stack)",
    )
    parser.add_argument(
        "--password",
        help="Override the password (skips Secrets Manager fetch)",
    )
    parser.add_argument(
        "--case",
        choices=["single-loss", "total-loss"],
        help=(
            "Run a destructive resilience test case instead of connectivity checks. "
            "single-loss: terminate one cluster node; verify volume reattach + data persistence. "
            "total-loss: terminate all three nodes; verify full cluster recovery from retained volumes. "
            "Expected runtime: ~5 min (single-loss), ~10-15 min (total-loss)."
        ),
    )
    parser.add_argument(
        "--timeout",
        type=int,
        help="Override the ASG replacement timeout in seconds (default: 900 single-loss, 1200 total-loss)",
    )
    args = parser.parse_args()

    logging.basicConfig(format="%(message)s", level=logging.INFO, stream=sys.stdout)

    try:
        outputs_path = _resolve_outputs_path(args.outputs_file, args.stack)
        config = load_config(outputs_path, args.password)
    except (FileNotFoundError, ValueError) as exc:
        log.error("ERROR: %s", exc)
        sys.exit(1)

    reporter = TestReporter()

    log.info("=== Neo4j EE Private Validator ===")
    log.info("")
    log.info("  Stack:   %s", config.stack_name)
    log.info("  Region:  %s", config.region)
    log.info("  Bastion: %s", config.bastion_id)
    log.info("  NLB:     %s", config.nlb_dns)
    if args.case:
        log.info("  Mode:    resilience/%s", args.case)
    log.info("")

    if args.case:
        from validate_private.resilience import run_single_loss, run_total_loss  # noqa: PLC0415

        if args.case == "single-loss":
            timeout = args.timeout or 900
            run_single_loss(config, reporter, timeout=timeout)
        else:
            timeout = args.timeout or 1200
            run_total_loss(config, reporter, timeout=timeout)
    else:
        run_checks(config, reporter)

    exit_code = reporter.summary(
        stack_name=config.stack_name,
        bastion_id=config.bastion_id,
    )
    sys.exit(exit_code)
