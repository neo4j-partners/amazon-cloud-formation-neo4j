"""Load EE Private stack configuration from the deploy file and Secrets Manager."""

from __future__ import annotations

import dataclasses
import getpass
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError


_REQUIRED_FIELDS = ("StackName", "Region", "Neo4jOperatorBastionId", "Neo4jInternalDNS", "AdvertisedDNS")


@dataclasses.dataclass(frozen=True)
class StackConfig:
    stack_name: str
    region: str
    bastion_id: str
    nlb_dns: str
    advertised_dns: str
    bolt_scheme: str
    password: str
    install_apoc: bool
    install_gds: bool


def _parse_outputs(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def _fetch_secret(secret_name: str, region: str) -> str:
    sm = boto3.client("secretsmanager", region_name=region)
    return sm.get_secret_value(SecretId=secret_name)["SecretString"]


def _certificate_type(fields: dict[str, str], region: str) -> str:
    cert_type = fields.get("CertificateType", "")
    if cert_type:
        return cert_type

    cert_arn = fields.get("CertificateArn", "")
    if not cert_arn:
        return ""

    try:
        acm = boto3.client("acm", region_name=region)
        cert = acm.describe_certificate(CertificateArn=cert_arn)["Certificate"]
    except ClientError:
        return ""
    return cert.get("Type", "")


def _bolt_scheme(fields: dict[str, str], region: str) -> str:
    base = "bolt" if fields.get("NumberOfServers", "3") == "1" else "neo4j"
    self_signed = fields.get("SelfSignedCertificate", "").lower() == "true"
    cert_type = _certificate_type(fields, region)
    if self_signed or cert_type in {"IMPORTED", "PRIVATE"}:
        return f"{base}+ssc"
    return f"{base}+s"


def load_config(
    outputs_path: Path,
    password_override: str | None = None,
) -> StackConfig:
    if not outputs_path.exists():
        raise FileNotFoundError(
            f"{outputs_path} not found. Run deploy.py first to create a stack."
        )

    fields = _parse_outputs(outputs_path)

    missing = [f for f in _REQUIRED_FIELDS if f not in fields]
    if missing:
        raise ValueError(
            f"Required field(s) missing from {outputs_path.name}: {', '.join(missing)}"
        )

    deployment_mode = fields.get("DeploymentMode", "Public")
    if deployment_mode not in ("Private", "ExistingVpc"):
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
    bolt_scheme = _bolt_scheme(fields, region)

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
        advertised_dns=fields["AdvertisedDNS"],
        bolt_scheme=bolt_scheme,
        password=password,
        install_apoc=fields.get("InstallAPOC", "no").lower() == "yes",
        install_gds=fields.get("InstallGDS", "false").lower() == "true",
    )
