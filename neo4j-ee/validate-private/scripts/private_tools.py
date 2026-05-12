"""Shared helpers for validate-private uv scripts."""

from __future__ import annotations

from pathlib import Path
import sys

import boto3
from botocore.exceptions import ClientError


SCRIPTS_DIR = Path(__file__).resolve().parent
VALIDATE_PRIVATE_DIR = SCRIPTS_DIR.parent
EE_DIR = VALIDATE_PRIVATE_DIR.parent
DEPLOY_DIR = EE_DIR / ".deploy"


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
            print(f"ERROR: File not found: {path}", file=sys.stderr)
        else:
            print(f"ERROR: No .txt files in {DEPLOY_DIR}/", file=sys.stderr)
        raise SystemExit("Run deploy.py first, or pass a stack name.")
    return path


def require_field(fields: dict[str, str], key: str, source: Path) -> str:
    value = fields.get(key, "")
    if not value:
        raise SystemExit(f"ERROR: Could not read {key} from {source}.")
    return value


def require_private_mode(fields: dict[str, str]) -> None:
    mode = fields.get("DeploymentMode", "Public")
    if mode not in {"Private", "ExistingVpc"}:
        stack_name = fields.get("StackName", "unknown")
        raise SystemExit(
            "ERROR: This command requires a Private or ExistingVpc stack.\n"
            f"Stack '{stack_name}' has DeploymentMode={mode}."
        )


def certificate_type(fields: dict[str, str]) -> str:
    cert_type = fields.get("CertificateType", "")
    if cert_type:
        return cert_type

    cert_arn = fields.get("CertificateArn", "")
    region = fields.get("Region", "")
    if not cert_arn or not region:
        return ""

    try:
        acm = boto3.client("acm", region_name=region)
        cert = acm.describe_certificate(CertificateArn=cert_arn)["Certificate"]
    except ClientError:
        return ""
    return cert.get("Type", "")


def resolve_bolt_scheme(fields: dict[str, str]) -> str:
    number_of_servers = fields.get("NumberOfServers", "3")
    base = "bolt" if number_of_servers == "1" else "neo4j"
    self_signed = fields.get("SelfSignedCertificate", "").lower() == "true"
    cert_type = certificate_type(fields)

    # These operator tools do not install a custom CA bundle into Browser,
    # cypher-shell, or the bastion smoke-test driver. Use +ssc for certs that
    # are not expected to chain to the client system trust store.
    if self_signed or cert_type in {"IMPORTED", "PRIVATE"}:
        return f"{base}+ssc"
    return f"{base}+s"
