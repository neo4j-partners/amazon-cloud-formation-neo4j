"""CLI entry point: uv run ssm-check-sessions"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import subprocess
import sys

import boto3


_NEO4J_EE_DIR = Path(__file__).resolve().parent.parent.parent.parent
_DEPLOY_DIR = _NEO4J_EE_DIR / ".deploy"
_ASG_FIELDS = ("Neo4jNode1ASGName", "Neo4jNode2ASGName", "Neo4jNode3ASGName")


@dataclass(frozen=True)
class SessionInfo:
    session_id: str
    owner: str
    start_date: str
    status: str


def _parse_outputs(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def _resolve_outputs_path(stack: str | None) -> Path:
    if stack:
        return _DEPLOY_DIR / f"{stack.removesuffix('.txt')}.txt"
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
        "Run deploy.py first, or pass a stack name."
    )


def _require_field(fields: dict[str, str], key: str, source: Path) -> str:
    value = fields.get(key, "")
    if not value:
        raise ValueError(f"Could not read {key} from {source}.")
    return value


def _require_private_mode(fields: dict[str, str]) -> None:
    mode = fields.get("DeploymentMode", "Public")
    if mode not in {"Private", "ExistingVpc"}:
        stack_name = fields.get("StackName", "unknown")
        raise ValueError(
            "This command requires a Private or ExistingVpc stack. "
            f"Stack '{stack_name}' has DeploymentMode={mode}."
        )


def _in_service_instances(autoscaling, asg_name: str) -> list[str]:
    response = autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name],
    )
    groups = response.get("AutoScalingGroups", [])
    if not groups:
        return []
    return [
        instance["InstanceId"]
        for instance in groups[0].get("Instances", [])
        if instance.get("LifecycleState") == "InService"
    ]


def _active_sessions(ssm, instance_id: str) -> list[SessionInfo]:
    paginator = ssm.get_paginator("describe_sessions")
    sessions: list[SessionInfo] = []
    for page in paginator.paginate(
        State="Active",
        Filters=[{"key": "Target", "value": instance_id}],
    ):
        for session in page.get("Sessions", []):
            sessions.append(
                SessionInfo(
                    session_id=session.get("SessionId", ""),
                    owner=session.get("Owner", ""),
                    start_date=str(session.get("StartDate", "")),
                    status=session.get("Status", ""),
                )
            )
    return sessions


def _print_sessions(sessions: list[SessionInfo]) -> None:
    if not sessions:
        print("  (none)")
        return

    rows = [
        ("SessionId", "Owner", "StartDate", "Status"),
        *[
            (session.session_id, session.owner, session.start_date, session.status)
            for session in sessions
        ],
    ]
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    for index, row in enumerate(rows):
        print("  " + "  ".join(value.ljust(widths[i]) for i, value in enumerate(row)))
        if index == 0:
            print("  " + "  ".join("-" * width for width in widths))


def _print_local_ports() -> None:
    result = subprocess.run(
        ["lsof", "-i", ":7473", "-i", ":7687"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.stdout.strip():
        print(result.stdout.rstrip())
    else:
        print("  Ports 7473 and 7687 are free")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "List active SSM sessions for a Neo4j EE Private stack's instances."
        ),
    )
    parser.add_argument(
        "stack",
        nargs="?",
        help="Stack name. Defaults to the most recent ../.deploy/*.txt file.",
    )
    return parser.parse_args(argv)


def main() -> None:
    args = _parse_args(sys.argv[1:])

    try:
        outputs_path = _resolve_outputs_path(args.stack)
        fields = _parse_outputs(outputs_path)
        _require_private_mode(fields)
        stack_name = _require_field(fields, "StackName", outputs_path)
        region = _require_field(fields, "Region", outputs_path)
        bastion_id = _require_field(fields, "Neo4jOperatorBastionId", outputs_path)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    autoscaling = boto3.client("autoscaling", region_name=region)
    ssm = boto3.client("ssm", region_name=region)

    print(f"=== Active SSM sessions for stack: {stack_name} ===")

    instance_ids: list[str] = []
    for key in _ASG_FIELDS:
        asg_name = fields.get(key, "")
        if not asg_name:
            continue
        print(f"{key}: {asg_name}")
        instance_ids.extend(_in_service_instances(autoscaling, asg_name))

    instance_ids.append(bastion_id)

    print(f"Instances: {' '.join(instance_ids)}")
    print()

    for instance_id in instance_ids:
        print(f"--- Sessions for {instance_id} ---")
        _print_sessions(_active_sessions(ssm, instance_id))

    print()
    print("=== Local ports in use ===")
    _print_local_ports()
