"""Parse deploy output files and expose configuration as a typed dataclass."""

from __future__ import annotations

import contextlib
import dataclasses
import getpass
import sys
from collections.abc import Iterator
from pathlib import Path
from urllib.parse import urlparse

import time

from neo4j import Driver, GraphDatabase
from neo4j.exceptions import ClientError

LOCAL_HTTP_PORT = 7474
LOCAL_BOLT_PORT = 7687

_PUBLIC_REQUIRED_FIELDS = (
    "Neo4jBrowserURL",
    "Neo4jURI",
    "Username",
    "StackName",
    "Region",
)

_PRIVATE_REQUIRED_FIELDS = (
    "Neo4jInternalDNS",
    "Username",
    "StackName",
    "Region",
)

_NOT_A_LEADER_CODE = "Neo.ClientError.Cluster.NotALeader"


@dataclasses.dataclass(frozen=True)
class StackConfig:
    """Immutable configuration parsed from deploy.sh output (.deploy/<stack>.txt)."""

    browser_url: str  # e.g. http://<host>:7474
    neo4j_uri: str    # e.g. neo4j://<host>:7687
    username: str
    password: str
    stack_name: str
    region: str
    edition: str      # "ce" or "ee"
    install_apoc: bool
    host: str         # bare hostname extracted from browser_url
    deployment_mode: str = "Public"  # "Public" or "Private"
    nlb_dns: str = ""                # internal NLB DNS for Private mode

    @contextlib.contextmanager
    def driver(self) -> Iterator[Driver]:
        """Yield a Neo4j driver connected with this config's credentials."""
        if self.deployment_mode == "Private":
            # Use bolt:// (direct, no routing table) to the SSM tunnel.
            # The NLB routes each new TCP connection to a random cluster node.
            # Writes require the LEADER; probe with a no-op write and reconnect
            # until the NLB happens to route to the LEADER (typically 1-3 attempts).
            bolt_uri = f"bolt://localhost:{LOCAL_BOLT_PORT}"
            last_exc: Exception | None = None
            for _ in range(10):
                drv = GraphDatabase.driver(bolt_uri, auth=(self.username, self.password))
                try:
                    drv.execute_query("CREATE (n:_LeaderProbe) DELETE n")
                    yield drv
                    return
                except ClientError as exc:
                    drv.close()
                    if exc.code == _NOT_A_LEADER_CODE:
                        last_exc = exc
                        time.sleep(0.5)
                        continue
                    raise
                except Exception:
                    drv.close()
                    raise
            raise last_exc or RuntimeError(
                "Could not reach the cluster LEADER via the NLB after 10 attempts."
            )
        else:
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
    edition: str,
    password_override: str | None = None,
) -> StackConfig:
    if not outputs_path.exists():
        raise FileNotFoundError(
            f"{outputs_path} not found. Run deploy.sh first to create a stack."
        )

    fields = _parse_outputs(outputs_path)

    deployment_mode = fields.get("DeploymentMode", "Public")
    required = _PRIVATE_REQUIRED_FIELDS if deployment_mode == "Private" else _PUBLIC_REQUIRED_FIELDS

    missing = [f for f in required if f not in fields]
    if missing:
        raise ValueError(
            f"Required field(s) missing from {outputs_path.name}: {', '.join(missing)}"
        )

    file_edition = fields.get("Edition", "").lower()
    if file_edition and file_edition != edition:
        raise ValueError(
            f"--edition {edition} does not match the outputs file "
            f"(Edition={file_edition} in {outputs_path.name})"
        )

    if deployment_mode == "Private":
        nlb_dns = fields["Neo4jInternalDNS"]
        browser_url = f"http://localhost:{LOCAL_HTTP_PORT}"
        neo4j_uri = f"neo4j://localhost:{LOCAL_BOLT_PORT}"
        host = "localhost"
    else:
        nlb_dns = ""
        browser_url = fields["Neo4jBrowserURL"]
        neo4j_uri = fields["Neo4jURI"]
        host = urlparse(browser_url).hostname or browser_url

    install_apoc = fields.get("InstallAPOC", "no").lower() == "yes"

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
        edition=edition,
        install_apoc=install_apoc,
        host=host,
        deployment_mode=deployment_mode,
        nlb_dns=nlb_dns,
    )
