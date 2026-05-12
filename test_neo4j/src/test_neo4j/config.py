"""Parse deploy output files and expose configuration as a typed dataclass."""

from __future__ import annotations

import contextlib
import dataclasses
import getpass
import sys
from collections.abc import Iterator
from pathlib import Path
from urllib.parse import urlparse

from neo4j import Driver, GraphDatabase


_REQUIRED_FIELDS_CE = (
    "Neo4jBrowserURL",
    "Neo4jURI",
    "Username",
    "StackName",
    "Region",
)

_REQUIRED_FIELDS_EE_PUBLIC = (
    "Neo4jBrowserURL",
    "Neo4jURI",
    "Username",
    "StackName",
    "Region",
)

_REQUIRED_FIELDS_COMMON = (
    "Username",
    "StackName",
    "Region",
)


@dataclasses.dataclass(frozen=True)
class StackConfig:
    """Immutable configuration parsed from deploy.sh output (.deploy/<stack>.txt)."""

    browser_url: str  # e.g. http://<host>:7474
    neo4j_uri: str    # e.g. neo4j://<host>:7687 or neo4j+ssc://<host>:7687
    username: str
    password: str
    stack_name: str
    region: str
    install_apoc: bool
    host: str         # bare hostname extracted from browser_url
    edition: str      # "ce" or "ee"
    number_of_servers: int  # 1 or 3 for EE
    # Set when deploy.py installed a licence via --bloom-license-secret-id /
    # --gds-license-secret-id; absence means the licence checks are skipped.
    bloom_licensed: bool
    gds_licensed: bool
    # Bloom plugin is installed unconditionally on the EE templates' UserData,
    # so this is expected to be True on every EE deploy; the field exists so
    # CE deploys can opt out and so future template changes that drop Bloom
    # can be reflected by deploy.py without touching the test runner.
    bloom_expected: bool
    # gds_expected mirrors the InstallGDS template parameter recorded by
    # deploy.py; the GDS plugin install is gated on this in the UserData.
    gds_expected: bool
    # bolt_tls_enabled is True when deploy.py installed a Bolt TLS certificate
    # (recorded as BoltTlsSecretArn). When True the runner uses the +ssc Bolt
    # scheme so the Neo4j driver tolerates the self-signed cert.
    bolt_tls_enabled: bool
    # AMI used by the running cluster instances; "local" when built by
    # marketplace/create-ami.sh (Marketplace or iteration mode), "marketplace"
    # when sourced from the live Marketplace listing via --marketplace.
    ami_id: str
    ami_source: str

    @contextlib.contextmanager
    def driver(self) -> Iterator[Driver]:
        """Yield a Neo4j driver connected with this config's credentials."""
        drv = GraphDatabase.driver(
            self.neo4j_uri,
            auth=(self.username, self.password),
        )
        try:
            yield drv
        finally:
            drv.close()


def _parse_outputs(path: Path) -> dict[str, str]:
    """Read a 'Key = Value' file into a dict, stripping whitespace."""
    fields: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def load_config(
    outputs_path: Path,
    password_override: str | None = None,
) -> StackConfig:
    if not outputs_path.exists():
        raise FileNotFoundError(
            f"{outputs_path} not found. Run deploy.sh first to create a stack."
        )

    fields = _parse_outputs(outputs_path)

    edition = fields.get("Edition", "ce").lower()
    number_of_servers = int(fields.get("NumberOfServers", "1"))

    missing = [f for f in _REQUIRED_FIELDS_COMMON if f not in fields]
    if missing:
        raise ValueError(
            f"Required field(s) missing from {outputs_path.name}: {', '.join(missing)}"
        )

    if "Neo4jBrowserURL" not in fields or "Neo4jURI" not in fields:
        if edition == "ee":
            raise ValueError(
                "This test runner only supports public EE stacks (internet-facing NLB). "
                "The deploy output is missing Neo4jBrowserURL and Neo4jURI — "
                "private EE stacks require SSM tunneling and are not supported here."
            )
        raise ValueError(
            f"Required field(s) missing from {outputs_path.name}: "
            + ", ".join(f for f in ("Neo4jBrowserURL", "Neo4jURI") if f not in fields)
        )

    browser_url = fields["Neo4jBrowserURL"]
    neo4j_uri = fields["Neo4jURI"]
    host = urlparse(browser_url).hostname or browser_url

    install_apoc = fields.get("InstallAPOC", "no").lower() == "yes"

    # deploy.py records BoltTlsSecretArn when --tls was used; in that mode the
    # stack enforces server.bolt.tls_level=REQUIRED so the runner has to use the
    # +ssc scheme to tolerate the self-signed cert generated at deploy time.
    bolt_tls_enabled = bool(fields.get("BoltTlsSecretArn"))
    if bolt_tls_enabled and neo4j_uri.startswith("neo4j://"):
        neo4j_uri = "neo4j+ssc://" + neo4j_uri[len("neo4j://"):]

    password = (
        password_override
        if password_override is not None
        else fields.get("Password", "")
    )
    if not password and sys.stdin.isatty():
        password = getpass.getpass("Enter neo4j password: ")
    if not password:
        raise ValueError(
            "No password available. Provide --password or ensure Password is in "
            f"{outputs_path.name}."
        )

    return StackConfig(
        browser_url=browser_url,
        neo4j_uri=neo4j_uri,
        username=fields["Username"],
        password=password,
        stack_name=fields["StackName"],
        region=fields["Region"],
        install_apoc=install_apoc,
        host=host,
        edition=edition,
        number_of_servers=number_of_servers,
        bloom_licensed=bool(fields.get("BloomLicenseSecretId")),
        gds_licensed=bool(fields.get("GdsLicenseSecretId")),
        bloom_expected=fields.get("BloomExpected", "yes" if edition == "ee" else "no").lower() == "yes",
        gds_expected=fields.get("InstallGDS", "false").lower() == "true",
        bolt_tls_enabled=bolt_tls_enabled,
        ami_id=fields.get("AmiId", ""),
        ami_source=fields.get("AmiSource", ""),
    )
