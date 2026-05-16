"""License secret handling for EE deploy tooling."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

import boto3


def create_local_license_secret(
    sm,
    stack_name: str,
    product: str,
    path: Path,
) -> str:
    """Create a temporary Secrets Manager secret from a local license file."""
    license_text = path.read_text().strip()
    if not license_text:
        sys.exit(f"ERROR: Local {product} licence file is empty: {path}")

    secret_name = f"neo4j/{stack_name}/licenses/{product}"
    response = sm.create_secret(
        Name=secret_name,
        Description=(
            f"Temporary Neo4j {product.upper()} licence for deploy.py stack "
            f"{stack_name}. Created from {path.name}."
        ),
        SecretString=license_text,
        Tags=[
            {"Key": "StackName", "Value": stack_name},
            {"Key": "CreatedBy", "Value": "neo4j-ee/deploy.py"},
            {"Key": "LicenseProduct", "Value": product},
        ],
    )
    return response["ARN"]


def resolve_license_secret_arns(
    args: argparse.Namespace,
    region: str,
    stack_name: str,
    local_license_files: dict[str, Path],
) -> tuple[str, str, list[str]]:
    """Resolve explicit or local licence inputs to Secrets Manager ARNs."""
    sm = boto3.client("secretsmanager", region_name=region)
    bloom_input = args.bloom_license_secret_id
    gds_input = args.gds_license_secret_id
    created_secret_arns: list[str] = []

    if not args.no_local_licenses:
        local_specs = [
            ("bloom", local_license_files["bloom"], bloom_input, not args.no_bloom),
            ("gds", local_license_files["gds"], gds_input, not args.no_gds),
        ]
        for product, path, explicit_secret, install_enabled in local_specs:
            if explicit_secret or not path.exists():
                continue
            if not install_enabled:
                print(
                    f"Local {product.upper()} licence present but ignored "
                    "because the plugin is disabled."
                )
                continue
            secret_arn = create_local_license_secret(sm, stack_name, product, path)
            created_secret_arns.append(secret_arn)
            if product == "bloom":
                bloom_input = secret_arn
            else:
                gds_input = secret_arn
            print(
                f"Local {product.upper()} licence uploaded to Secrets "
                f"Manager: {secret_arn}"
            )

    def _to_arn(secret_input: str | None) -> str:
        if not secret_input:
            return ""
        if secret_input.startswith("arn:"):
            return secret_input
        return sm.describe_secret(SecretId=secret_input)["ARN"]

    return _to_arn(bloom_input), _to_arn(gds_input), created_secret_arns
