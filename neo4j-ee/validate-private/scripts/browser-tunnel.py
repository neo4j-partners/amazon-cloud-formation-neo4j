#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3"]
# ///

"""Open an SSM port-forward tunnel to Neo4j Browser on port 7474."""

from __future__ import annotations

import argparse
import os

from private_tools import (
    read_outputs,
    require_field,
    require_private_mode,
    resolve_bolt_scheme,
    resolve_outputs_file,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Open an SSM port-forward tunnel to Neo4j Browser."
    )
    parser.add_argument("stack_name", nargs="?", help="EE stack name.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    outputs_file = resolve_outputs_file(args.stack_name)
    fields = read_outputs(outputs_file)
    require_private_mode(fields)

    stack_name = require_field(fields, "StackName", outputs_file)
    region = require_field(fields, "Region", outputs_file)
    bastion_id = require_field(fields, "Neo4jOperatorBastionId", outputs_file)
    nlb_dns = require_field(fields, "Neo4jInternalDNS", outputs_file)
    bolt_scheme = resolve_bolt_scheme(fields)
    local_scheme = "bolt+ssc" if bolt_scheme.endswith("+ssc") else "bolt"

    print("=== Neo4j Browser Tunnel ===")
    print()
    print(f"  Stack:         {stack_name}")
    print(f"  Region:        {region}")
    print(f"  Bastion:       {bastion_id}")
    print()
    print(f"  Tunnel:  localhost:7474  ->  {nlb_dns}:7474")
    print()
    print("  Once the tunnel opens:")
    print("    Browser: http://localhost:7474")
    print(f"    Bolt:    {local_scheme}://localhost:7687")
    print("             if the Bolt tunnel is also open")
    print()
    print("  Press Ctrl-C to close.")
    print()

    os.execvp(
        "aws",
        [
            "aws",
            "ssm",
            "start-session",
            "--target",
            bastion_id,
            "--region",
            region,
            "--document-name",
            "AWS-StartPortForwardingSessionToRemoteHost",
            "--parameters",
            f"host={nlb_dns},portNumber=7474,localPortNumber=7474",
        ],
    )


if __name__ == "__main__":
    main()
