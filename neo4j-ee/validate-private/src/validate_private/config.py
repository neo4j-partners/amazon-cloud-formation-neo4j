"""Load EE Private stack configuration from the deploy file and Secrets Manager."""

from __future__ import annotations

import dataclasses
import getpass
import sys
from pathlib import Path


_REQUIRED_FIELDS = ("StackName", "Region", "Neo4jOperatorBastionId", "Neo4jInternalDNS")


@dataclasses.dataclass(frozen=True)
class StackConfig:
    stack_name: str
    region: str
    bastion_id: str
    nlb_dns: str
    password: str
    install_apoc: bool


def _parse_outputs(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def _fetch_secret(secret_name: str, region: str) -> str:
    import boto3
    sm = boto3.client("secretsmanager", region_name=region)
    return sm.get_secret_value(SecretId=secret_name)["SecretString"]


def load_config(
    outputs_path: Path,
    password_override: str | None = None,
) -> StackConfig:
    if not outputs_path.exists():
        raise FileNotFoundError(
            f"{outputs_path} not found. Run deploy.sh first to create a stack."
        )

    fields = _parse_outputs(outputs_path)

    missing = [f for f in _REQUIRED_FIELDS if f not in fields]
    if missing:
        raise ValueError(
            f"Required field(s) missing from {outputs_path.name}: {', '.join(missing)}"
        )

    deployment_mode = fields.get("DeploymentMode", "Public")
    if deployment_mode != "Private":
        raise ValueError(
            f"validate-private only supports Private-mode stacks. "
            f"This stack has DeploymentMode={deployment_mode}."
        )

    edition = fields.get("Edition", "").lower()
    if edition and edition != "ee":
        raise ValueError(
            f"validate-private only supports Enterprise Edition stacks. "
            f"This stack has Edition={edition}."
        )

    stack_name = fields["StackName"]
    region = fields["Region"]
    secret_name = f"neo4j/{stack_name}/password"

    if password_override is not None:
        password = password_override
    else:
        try:
            password = _fetch_secret(secret_name, region)
        except Exception:
            password = fields.get("Password", "")

    if not password and sys.stdin.isatty():
        password = getpass.getpass("Enter neo4j password: ")
    if not password:
        raise ValueError(
            f"No password available. Ensure the Secrets Manager secret "
            f"'{secret_name}' exists, or provide --password."
        )

    return StackConfig(
        stack_name=stack_name,
        region=region,
        bastion_id=fields["Neo4jOperatorBastionId"],
        nlb_dns=fields["Neo4jInternalDNS"],
        password=password,
        install_apoc=fields.get("InstallAPOC", "no").lower() == "yes",
    )
