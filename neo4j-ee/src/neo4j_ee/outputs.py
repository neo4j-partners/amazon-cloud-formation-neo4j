"""Shared deploy-output file helpers.

Deploy output files use a simple `Key = Value` format. Keep parsing and
resolution behavior here so deploy, validation, sample app, and test tooling do
not drift.
"""

from __future__ import annotations

from pathlib import Path


def parse_key_value_text(text: str) -> dict[str, str]:
    """Parse `Key = Value` lines into a dictionary."""
    fields: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    return fields


def read_outputs(path: Path) -> dict[str, str]:
    """Read a deploy output file into a dictionary."""
    return parse_key_value_text(path.read_text())


def latest_outputs_file(deploy_dir: Path, pattern: str = "*.txt") -> Path | None:
    """Return the most recently modified output file matching pattern."""
    if not deploy_dir.is_dir():
        return None
    candidates = sorted(
        deploy_dir.glob(pattern),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def resolve_outputs_file(
    deploy_dir: Path,
    stack_name: str | None,
    *,
    pattern: str = "*.txt",
) -> Path:
    """Resolve an explicit stack name or the newest deploy output file."""
    if stack_name:
        path = deploy_dir / f"{stack_name.removesuffix('.txt')}.txt"
    else:
        path = latest_outputs_file(deploy_dir, pattern) or Path()

    if path.is_file():
        return path

    if stack_name:
        raise FileNotFoundError(f"File not found: {path}")
    raise FileNotFoundError(f"No {pattern} files in {deploy_dir}")


def require_field(fields: dict[str, str], key: str, source: Path) -> str:
    """Return a required output field or raise a clear ValueError."""
    value = fields.get(key, "")
    if not value:
        raise ValueError(f"Could not read {key} from {source}.")
    return value


def truthy(value: str | None) -> bool:
    """Return whether a deploy output field uses a truthy string."""
    return (value or "").lower() in {"1", "true", "yes", "y"}


def resolve_bolt_scheme(fields: dict[str, str]) -> str:
    """Return the Bolt URI scheme implied by output fields."""
    base = "bolt" if fields.get("NumberOfServers", "3") == "1" else "neo4j"
    if fields.get("BoltTlsSecretArn", ""):
        return f"{base}+ssc"
    return base


def require_private_mode(fields: dict[str, str]) -> None:
    """Validate that output fields describe a private EE deployment."""
    mode = fields.get("DeploymentMode", "Public")
    if mode not in {"Private", "ExistingVpc"}:
        stack_name = fields.get("StackName", "unknown")
        raise ValueError(
            "This command requires a Private or ExistingVpc stack. "
            f"Stack '{stack_name}' has DeploymentMode={mode}."
        )
