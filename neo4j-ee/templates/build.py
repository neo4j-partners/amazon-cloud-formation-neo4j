#!/usr/bin/env python3
"""
Assembles deployable CloudFormation templates from source partials in src/.

Usage:
    python build.py            # generate all templates
    python build.py --verify   # exit non-zero if generated output differs from committed
"""

import argparse
import difflib
import sys
from pathlib import Path

SRC = Path(__file__).parent / "src"
OUT = Path(__file__).parent

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


def _userdata_block(topology: str, base_indent: int = 8) -> str:
    """Return the UserData: Fn::Base64: !Join [...] block as YAML text."""
    sh_content = (SRC / f"userdata-{topology}.sh").read_text()

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


def _read(filename: str) -> str:
    return (SRC / filename).read_text()


def _assemble_private() -> str:
    asg_content = _read("asg.yaml")
    userdata = _userdata_block("private")
    placeholder = "        # __USERDATA__\n"
    if placeholder not in asg_content:
        print("ERROR: # __USERDATA__ placeholder not found in src/asg.yaml", file=sys.stderr)
        sys.exit(1)
    asg_content = asg_content.replace(placeholder, userdata)

    return "".join([
        GENERATED_HEADER,
        "AWSTemplateFormatVersion: '2010-09-09'\n",
        "Description: Neo4j Enterprise Edition — Private\n",
        "Metadata:\n",
        _read("metadata-private.yaml"),
        "\n",
        "Parameters:\n",
        _read("parameters-common.yaml"),
        "\n",
        _read("parameters-tls.yaml"),
        "\n",
        _read("parameters-private.yaml"),
        "\n",
        "Conditions:\n",
        _read("conditions-private.yaml"),
        "\n",
        "Resources:\n",
        _read("iam.yaml"),
        "\n",
        _read("security-groups.yaml"),
        "\n",
        _read("ebs-volumes.yaml"),
        "\n",
        asg_content,
        "\n",
        _read("networking-private.yaml"),
        "\n",
        _read("stack-config.yaml"),
        "\n",
        _read("observability.yaml"),
        "\n",
        "Outputs:\n",
        _read("outputs-private.yaml"),
    ])


def _assemble_public() -> str:
    asg_content = _read("asg-public.yaml")
    userdata = _userdata_block("public")
    placeholder = "        # __USERDATA__\n"
    if placeholder not in asg_content:
        print("ERROR: # __USERDATA__ placeholder not found in src/asg-public.yaml", file=sys.stderr)
        sys.exit(1)
    asg_content = asg_content.replace(placeholder, userdata)

    return "".join([
        GENERATED_HEADER,
        "AWSTemplateFormatVersion: '2010-09-09'\n",
        "Description: Neo4j Enterprise Edition — Public\n",
        "Metadata:\n",
        _read("metadata-public.yaml"),
        "\n",
        "Parameters:\n",
        _read("parameters-common.yaml"),
        "\n",
        _read("parameters-tls.yaml"),
        "\n",
        _read("parameters-public.yaml"),
        "\n",
        "Conditions:\n",
        _read("conditions-public.yaml"),
        "\n",
        "Resources:\n",
        _read("iam-public.yaml"),
        "\n",
        _read("security-groups-public.yaml"),
        "\n",
        _read("ebs-volumes.yaml"),
        "\n",
        asg_content,
        "\n",
        _read("networking-public.yaml"),
        "\n",
        _read("password-secret.yaml"),
        "\n",
        _read("observability.yaml"),
        "\n",
        "Outputs:\n",
        _read("outputs-public.yaml"),
    ])


def _assemble_existing_vpc() -> str:
    asg_content = _read("asg-existing-vpc.yaml")
    userdata = _userdata_block("existing-vpc")
    placeholder = "        # __USERDATA__\n"
    if placeholder not in asg_content:
        print("ERROR: # __USERDATA__ placeholder not found in src/asg-existing-vpc.yaml", file=sys.stderr)
        sys.exit(1)
    asg_content = asg_content.replace(placeholder, userdata)

    return "".join([
        GENERATED_HEADER,
        "AWSTemplateFormatVersion: '2010-09-09'\n",
        "Description: Neo4j Enterprise Edition — Private, Existing VPC\n",
        "Metadata:\n",
        _read("metadata-existing-vpc.yaml"),
        "\n",
        "Parameters:\n",
        _read("parameters-common.yaml"),
        "\n",
        _read("parameters-tls.yaml"),
        "\n",
        _read("parameters-existing-vpc.yaml"),
        "\n",
        "Rules:\n",
        _read("rules-existing-vpc.yaml"),
        "\n",
        "Conditions:\n",
        _read("conditions-existing-vpc.yaml"),
        "\n",
        "Resources:\n",
        _read("iam.yaml"),
        "\n",
        _read("security-groups-existing-vpc.yaml"),
        "\n",
        _read("ebs-volumes.yaml"),
        "\n",
        asg_content,
        "\n",
        _read("networking-existing-vpc.yaml"),
        "\n",
        _read("stack-config-existing-vpc.yaml"),
        "\n",
        _read("observability-existing-vpc.yaml"),
        "\n",
        "Outputs:\n",
        _read("outputs-existing-vpc.yaml"),
    ])


def _diff_userdata_scripts() -> None:
    """Print a diff of the three UserData scripts; runs on every build."""
    scripts = {
        "private": (SRC / "userdata-private.sh").read_text().splitlines(),
        "public": (SRC / "userdata-public.sh").read_text().splitlines(),
        "existing-vpc": (SRC / "userdata-existing-vpc.sh").read_text().splitlines(),
    }
    for a, b in [("private", "public"), ("private", "existing-vpc")]:
        diff = list(difflib.unified_diff(
            scripts[a], scripts[b],
            fromfile=f"userdata-{a}.sh",
            tofile=f"userdata-{b}.sh",
            lineterm="",
        ))
        if diff:
            print(f"\nUserData diff ({a} vs {b}):")
            for line in diff[:60]:
                print(line)
            if len(diff) > 60:
                print(f"  ... ({len(diff) - 60} more lines)")
        else:
            print(f"UserData: {a} and {b} are identical")


_TEMPLATES = [
    ("neo4j-private.template.yaml", _assemble_private),
    ("neo4j-public.template.yaml", _assemble_public),
    ("neo4j-private-existing-vpc.template.yaml", _assemble_existing_vpc),
]


def _build() -> None:
    for filename, assembler in _TEMPLATES:
        out_path = OUT / filename
        out_path.write_text(assembler())
        print(f"wrote {out_path.relative_to(OUT.parent)}")

    print()
    _diff_userdata_scripts()


def _verify() -> None:
    failed = False
    for filename, assembler in _TEMPLATES:
        committed_path = OUT / filename
        if not committed_path.exists():
            print(f"ERROR: {filename} not found; run build.py first", file=sys.stderr)
            sys.exit(1)
        generated = assembler()
        committed = committed_path.read_text()
        if generated == committed:
            print(f"{filename} is up to date")
            continue
        diff = list(difflib.unified_diff(
            committed.splitlines(),
            generated.splitlines(),
            fromfile="committed",
            tofile="generated",
            lineterm="",
        ))
        print(f"ERROR: {filename} is out of date. Run build.py to regenerate.", file=sys.stderr)
        for line in diff[:80]:
            print(line, file=sys.stderr)
        if len(diff) > 80:
            print(f"  ... ({len(diff) - 80} more lines)", file=sys.stderr)
        failed = True
    if failed:
        sys.exit(1)


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
    if args.verify:
        _verify()
    else:
        _build()


if __name__ == "__main__":
    main()
