#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3"]
# ///

"""Open Browser and Bolt SSM tunnels for a deployed EE stack."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import time


SCRIPT_DIR = Path(__file__).resolve().parent
DEPLOY_DIR = SCRIPT_DIR / ".deploy"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Open Neo4j Browser and Bolt SSM tunnels for an EE stack."
    )
    parser.add_argument("stack_name", nargs="?", help="EE stack name.")
    return parser.parse_args()


def read_outputs(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def resolve_outputs_file(stack_name: str | None) -> Path:
    if stack_name:
        path = DEPLOY_DIR / f"{stack_name.removesuffix('.txt')}.txt"
    elif DEPLOY_DIR.is_dir():
        candidates = sorted(
            DEPLOY_DIR.glob("*.txt"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        path = candidates[0] if candidates else Path()
    else:
        path = Path()

    if not path.is_file():
        if stack_name:
            raise SystemExit(f"ERROR: File not found: {path}")
        raise SystemExit(f"ERROR: No .txt files in {DEPLOY_DIR}/")
    return path


def require_field(fields: dict[str, str], key: str, source: Path) -> str:
    value = fields.get(key, "")
    if not value:
        raise SystemExit(f"ERROR: Could not read {key} from {source}.")
    return value


def resolve_bolt_scheme(fields: dict[str, str]) -> str:
    if fields.get("BoltTlsSecretArn", ""):
        return "bolt+ssc"
    return "bolt"


def start_tunnel(
    region: str,
    bastion_id: str,
    nlb_host: str,
    port: int,
) -> subprocess.Popen:
    return subprocess.Popen(
        [
            "aws",
            "ssm",
            "start-session",
            "--region",
            region,
            "--target",
            bastion_id,
            "--document-name",
            "AWS-StartPortForwardingSessionToRemoteHost",
            "--parameters",
            f"host={nlb_host},portNumber={port},localPortNumber={port}",
        ]
    )


def stop_process(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


def main() -> None:
    os.environ.setdefault("AWS_PROFILE", "default")
    args = parse_args()
    outputs_file = resolve_outputs_file(args.stack_name)
    fields = read_outputs(outputs_file)

    region = require_field(fields, "Region", outputs_file)
    bastion_id = require_field(fields, "Neo4jOperatorBastionId", outputs_file)
    nlb_host = require_field(fields, "Neo4jInternalDNS", outputs_file)
    username = fields.get("Username", "neo4j")
    password = require_field(fields, "Password", outputs_file)
    stack_name = require_field(fields, "StackName", outputs_file)
    bolt_scheme = resolve_bolt_scheme(fields)

    print(f"Stack:         {stack_name}")
    print(f"Region:        {region}")
    print(f"Bastion:       {bastion_id}")
    print()
    print("Opening SSM port-forwards to localhost:7474 and localhost:7687")
    print()
    print("Then open: http://localhost:7474")
    print(f"Bolt URI:  {bolt_scheme}://localhost:7687")
    print(f"Username: {username}")
    print(f"Password: {password}")
    print()
    print("Press Ctrl-C to stop the tunnels.")
    print()

    bolt_process: subprocess.Popen | None = None
    try:
        bolt_process = start_tunnel(region, bastion_id, nlb_host, 7687)
        time.sleep(1)
        browser_process = start_tunnel(region, bastion_id, nlb_host, 7474)
        raise SystemExit(browser_process.wait())
    except KeyboardInterrupt:
        raise SystemExit(130)
    finally:
        stop_process(bolt_process)


if __name__ == "__main__":
    main()
