#!/usr/bin/env python3
"""
Assembles deployable CloudFormation templates from source partials in src/.

Usage:
    python build.py            # generate all templates
    python build.py --verify   # exit non-zero if generated output differs from committed
"""

import argparse
from dataclasses import dataclass
import difflib
import re
import sys
from pathlib import Path

SRC = Path(__file__).parent / "src"
OUT = Path(__file__).parent
PARTIALS = SRC / "partials"
PARTIAL_INCLUDE_RE = re.compile(
    r"^#\s*include\s+partials/([A-Za-z0-9_.-]+\.sh)\s*$",
    re.MULTILINE,
)
EMBED_CONF_RE = re.compile(
    r"^#\s*embed-conf\s+([A-Za-z0-9_.-]+\.conf)\s*$",
    re.MULTILINE,
)
EMBED_CONF_DEST = "/var/lib/neo4j/neo4j-base.conf"
EMBED_CONF_HEREDOC = "NEO4JBASE"

GENERATED_HEADER = """\
# GENERATED FILE — do not edit directly.
# Edit source partials in templates/src/ and run templates/build.py to regenerate.
"""

# ---------------------------------------------------------------------------
# UserData preamble
#
# Each entry is the YAML scalar text for one item in the Fn::Join list.
# String literals use YAML double-quote escaping: \n = newline, \" = quote.
# CF intrinsics are written in YAML mapping or tag form.
# ---------------------------------------------------------------------------

_PREAMBLE_COMMON = [
    '"#!/bin/bash\\n"',
    '"set -euo pipefail\\n"',
    '"echo Running startup script...\\n"',
    '"nodeCount="',
    "Ref: NumberOfServers",
    '"\\n"',
    '"loadBalancerDNSName="',
    "Fn::GetAtt: [Neo4jNetworkLoadBalancer,DNSName]",
    '"\\n"',
    '"stackName="',
    "Ref: AWS::StackName",
    '"\\n"',
    '"region="',
    "Ref: AWS::Region",
    '"\\n"',
    '"installGDS="',
    "Ref: InstallGDS",
    '"\\n"',
    '"installBloom="',
    "Ref: InstallBloom",
    '"\\n"',
    '"bloomLicenseSecretArn="',
    "Ref: BloomLicenseSecretArn",
    '"\\n"',
    '"gdsLicenseSecretArn="',
    "Ref: GdsLicenseSecretArn",
    '"\\n"',
]

# Present in all three templates — Bolt over an internet-facing NLB must be
# encryptable, so the public template carries TLS parameters too.
_PREAMBLE_TLS = [
    '"boltCertArn="',
    "Ref: BoltCertificateSecretArn",
    '"\\n"',
    '"boltAdvertisedDNS="',
    "Ref: BoltAdvertisedDNS",
    '"\\n"',
]


class BuildError(RuntimeError):
    """Raised when template source partials cannot be assembled."""


@dataclass(frozen=True)
class TemplateSpec:
    filename: str
    description: str
    metadata_partial: str
    parameter_partials: tuple[str, ...]
    rule_partials: tuple[str, ...]
    conditions_partial: str
    resource_partials: tuple[str, ...]
    userdata_resource_partial: str
    outputs_partial: str
    rules_blank_between_partials: bool = True


def _read(filename: str) -> str:
    try:
        return (SRC / filename).read_text()
    except FileNotFoundError as exc:
        raise BuildError(f"source partial src/{filename} not found") from exc


def _inline_partials(content: str, source_name: str) -> str:
    """Inline UserData partial markers in shell source content."""

    def replace(match: re.Match[str]) -> str:
        partial_name = match.group(1)
        partial_path = PARTIALS / partial_name
        if not partial_path.exists():
            raise BuildError(
                f"{source_name} references missing partial {partial_path}"
            )
        return partial_path.read_text().rstrip("\n")

    rendered = PARTIAL_INCLUDE_RE.sub(replace, content)
    if PARTIAL_INCLUDE_RE.search(rendered):
        raise BuildError(f"unresolved partial include marker remains in {source_name}")

    def embed_conf(match: re.Match[str]) -> str:
        conf_name = match.group(1)
        conf_path = SRC / conf_name
        if not conf_path.exists():
            raise BuildError(
                f"{source_name} references missing conf {conf_path}"
            )
        body = conf_path.read_text().rstrip("\n")
        return (
            f"cat > {EMBED_CONF_DEST} <<'{EMBED_CONF_HEREDOC}'\n"
            f"{body}\n"
            f"{EMBED_CONF_HEREDOC}"
        )

    rendered = EMBED_CONF_RE.sub(embed_conf, rendered)
    if EMBED_CONF_RE.search(rendered):
        raise BuildError(f"unresolved embed-conf marker remains in {source_name}")
    return rendered


def _userdata_block(base_indent: int = 8) -> str:
    """Return the UserData: Fn::Base64: !Join [...] block as YAML text."""
    source_name = "userdata.sh"
    sh_content = _inline_partials(_read(source_name), source_name)

    p = " " * base_indent         # UserData: level
    p2 = " " * (base_indent + 2)  # Fn::Base64: level
    p4 = " " * (base_indent + 4)  # !Join / outer list level
    p6 = " " * (base_indent + 6)  # inner list items
    p8 = " " * (base_indent + 8)  # block literal content

    items = _PREAMBLE_COMMON[:]
    items.extend(_PREAMBLE_TLS)

    result = [
        f"{p}UserData:\n",
        f"{p2}Fn::Base64:\n",
        f"{p4}!Join\n",
        f"{p4}- ''\n",
        f"{p4}- - {items[0]}\n",
    ]
    for item in items[1:]:
        result.append(f"{p6}- {item}\n")

    # .sh body as a single YAML block literal — preserves the script verbatim.
    result.append(f"{p6}- |\n")
    for line in sh_content.splitlines(keepends=True):
        stripped = line.rstrip("\n\r")
        if stripped:
            result.append(f"{p8}{stripped}\n")
        else:
            result.append("\n")

    return "".join(result)


def _asg_with_userdata(filename: str) -> str:
    asg_content = _read(filename)
    placeholder = "        # __USERDATA__\n"
    if placeholder not in asg_content:
        raise BuildError(f"# __USERDATA__ placeholder not found in src/{filename}")
    return asg_content.replace(placeholder, _userdata_block())


def _append_partials(
    parts: list[str],
    filenames: tuple[str, ...],
    *,
    blank_between_partials: bool = True,
) -> None:
    for index, filename in enumerate(filenames):
        parts.append(_read(filename))
        if blank_between_partials or index == len(filenames) - 1:
            parts.append("\n")


def _resource_partial(filename: str, spec: TemplateSpec) -> str:
    if filename == spec.userdata_resource_partial:
        return _asg_with_userdata(filename)
    return _read(filename)


def _append_resource_partials(parts: list[str], spec: TemplateSpec) -> None:
    for filename in spec.resource_partials:
        parts.append(_resource_partial(filename, spec))
        parts.append("\n")


def _assemble(spec: TemplateSpec) -> str:
    parts = [
        GENERATED_HEADER,
        "AWSTemplateFormatVersion: '2010-09-09'\n",
        f"Description: {spec.description}\n",
        "Metadata:\n",
        _read(spec.metadata_partial),
        "\n",
        "Parameters:\n",
    ]
    _append_partials(parts, spec.parameter_partials)
    parts.append("Rules:\n")
    _append_partials(
        parts,
        spec.rule_partials,
        blank_between_partials=spec.rules_blank_between_partials,
    )
    parts.extend([
        "Conditions:\n",
        _read(spec.conditions_partial),
        "\n",
        "Resources:\n",
    ])
    _append_resource_partials(parts, spec)
    parts.extend([
        "Outputs:\n",
        _read(spec.outputs_partial),
    ])
    return "".join(parts)


_PRIVATE_SPEC = TemplateSpec(
    filename="neo4j-private.template.yaml",
    description="Neo4j Enterprise Edition — Private",
    metadata_partial="metadata-private.yaml",
    parameter_partials=(
        "parameters-common.yaml",
        "parameters-tls.yaml",
        "parameters-private.yaml",
    ),
    rule_partials=("rules-common.yaml",),
    conditions_partial="conditions-private.yaml",
    resource_partials=(
        "iam.yaml",
        "security-groups.yaml",
        "ebs-volumes.yaml",
        "asg.yaml",
        "networking-private.yaml",
        "stack-config.yaml",
        "observability.yaml",
    ),
    userdata_resource_partial="asg.yaml",
    outputs_partial="outputs-private.yaml",
)

_PUBLIC_SPEC = TemplateSpec(
    filename="neo4j-public.template.yaml",
    description="Neo4j Enterprise Edition — Public",
    metadata_partial="metadata-public.yaml",
    parameter_partials=(
        "parameters-common.yaml",
        "parameters-tls.yaml",
        "parameters-public.yaml",
    ),
    rule_partials=("rules-common.yaml",),
    conditions_partial="conditions-public.yaml",
    resource_partials=(
        "iam-public.yaml",
        "security-groups-public.yaml",
        "ebs-volumes.yaml",
        "asg-public.yaml",
        "networking-public.yaml",
        "password-secret.yaml",
        "observability.yaml",
    ),
    userdata_resource_partial="asg-public.yaml",
    outputs_partial="outputs-public.yaml",
)

_EXISTING_VPC_SPEC = TemplateSpec(
    filename="neo4j-private-existing-vpc.template.yaml",
    description="Neo4j Enterprise Edition — Private, Existing VPC",
    metadata_partial="metadata-existing-vpc.yaml",
    parameter_partials=(
        "parameters-common.yaml",
        "parameters-tls.yaml",
        "parameters-existing-vpc.yaml",
    ),
    rule_partials=("rules-common.yaml", "rules-existing-vpc.yaml"),
    conditions_partial="conditions-existing-vpc.yaml",
    resource_partials=(
        "iam.yaml",
        "security-groups-existing-vpc.yaml",
        "ebs-volumes.yaml",
        "asg-existing-vpc.yaml",
        "networking-existing-vpc.yaml",
        "stack-config-existing-vpc.yaml",
        "observability-existing-vpc.yaml",
    ),
    userdata_resource_partial="asg-existing-vpc.yaml",
    outputs_partial="outputs-existing-vpc.yaml",
    rules_blank_between_partials=False,
)

_TEMPLATE_SPECS = [
    _PRIVATE_SPEC,
    _PUBLIC_SPEC,
    _EXISTING_VPC_SPEC,
]


def _assemble_private() -> str:
    return _assemble(_PRIVATE_SPEC)


def _assemble_public() -> str:
    return _assemble(_PUBLIC_SPEC)


def _assemble_existing_vpc() -> str:
    return _assemble(_EXISTING_VPC_SPEC)


def _build() -> None:
    for spec in _TEMPLATE_SPECS:
        out_path = OUT / spec.filename
        out_path.write_text(_assemble(spec))
        print(f"wrote {out_path.relative_to(OUT.parent)}")


def _verify() -> bool:
    failed = False
    for spec in _TEMPLATE_SPECS:
        committed_path = OUT / spec.filename
        if not committed_path.exists():
            raise BuildError(f"{spec.filename} not found; run build.py first")
        generated = _assemble(spec)
        committed = committed_path.read_text()
        if generated == committed:
            print(f"{spec.filename} is up to date")
            continue
        diff = list(difflib.unified_diff(
            committed.splitlines(),
            generated.splitlines(),
            fromfile="committed",
            tofile="generated",
            lineterm="",
        ))
        print(
            f"ERROR: {spec.filename} is out of date. Run build.py to regenerate.",
            file=sys.stderr,
        )
        for line in diff[:80]:
            print(line, file=sys.stderr)
        if len(diff) > 80:
            print(f"  ... ({len(diff) - 80} more lines)", file=sys.stderr)
        failed = True
    return not failed


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Assemble CloudFormation templates from source partials in src/",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="exit non-zero if committed templates differ from a fresh build",
    )
    args = parser.parse_args()
    try:
        if args.verify:
            if not _verify():
                sys.exit(1)
        else:
            _build()
    except BuildError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
