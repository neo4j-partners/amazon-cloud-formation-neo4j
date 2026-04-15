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


_REQUIRED_FIELDS = (
    "Neo4jBrowserURL",
    "Neo4jURI",
    "Username",
    "StackName",
    "Region",
)


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
    edition: str,
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

    file_edition = fields.get("Edition", "").lower()
    if file_edition and file_edition != edition:
        raise ValueError(
            f"--edition {edition} does not match the outputs file "
            f"(Edition={file_edition} in {outputs_path.name})"
        )

    browser_url = fields["Neo4jBrowserURL"]
    neo4j_uri = fields["Neo4jURI"]
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

    host = urlparse(browser_url).hostname or browser_url

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
    )
