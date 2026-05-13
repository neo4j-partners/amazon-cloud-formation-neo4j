"""AMI resolution helpers for EE deploy tooling."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys

import boto3


@dataclass(frozen=True)
class AmiInfo:
    ami_id: str
    source_ami_id: str
    source: str
    ssm_param_path: str
    copied_ami_id: str | None = None


def _wait_for_ami(ec2, ami_id: str, region: str) -> None:
    ec2.get_waiter("image_available").wait(
        ImageIds=[ami_id],
        WaiterConfig={"Delay": 30, "MaxAttempts": 60},
    )
    print(f"AMI available in {region}.")


def _tag_copied_ami(
    ec2, ami_id: str, source_ami_id: str, source_region: str
) -> None:
    try:
        ec2.create_tags(
            Resources=[ami_id],
            Tags=[
                {"Key": "SourceAmiId", "Value": source_ami_id},
                {"Key": "SourceRegion", "Value": source_region},
            ],
        )
    except Exception as exc:
        print(f"Warning: could not tag copied AMI {ami_id}: {exc}")


def resolve_ami(
    args,
    *,
    region: str,
    stack_name: str,
    script_dir: Path,
    source_region: str,
) -> AmiInfo:
    """Resolve the AMI used by the stack and create an SSM image parameter."""
    if args.marketplace:
        return AmiInfo(
            ami_id="",
            source_ami_id="",
            source="marketplace",
            ssm_param_path="",
        )

    ami_id_file = script_dir / "marketplace" / "ami-id.txt"
    if not ami_id_file.exists():
        sys.exit(
            f"ERROR: {ami_id_file} not found. Run marketplace/create-ami.sh first,\n"
            "       or use --marketplace to deploy from the live Marketplace listing."
        )
    source_ami_id = ami_id_file.read_text().strip()
    ec2 = boto3.client("ec2", region_name=region)
    copied_ami_id: str | None = None

    if region != source_region:
        existing = ec2.describe_images(
            Owners=["self"],
            Filters=[
                {
                    "Name": "description",
                    "Values": [f"Copied from {source_ami_id} in {source_region}"],
                }
            ],
        )["Images"]
        available = sorted(
            [img for img in existing if img["State"] == "available"],
            key=lambda img: img["CreationDate"],
            reverse=True,
        )
        pending = [img for img in existing if img["State"] == "pending"]
        if available:
            copied_ami_id = available[0]["ImageId"]
            print(f"Reusing existing copied AMI {copied_ami_id} in {region}.")
        elif pending:
            copied_ami_id = pending[0]["ImageId"]
            print(
                f"Found in-progress AMI copy {copied_ami_id} in {region} - "
                "waiting for it to become available..."
            )
            _wait_for_ami(ec2, copied_ami_id, region)
            _tag_copied_ami(ec2, copied_ami_id, source_ami_id, source_region)
        else:
            print(f"Copying AMI {source_ami_id} from {source_region} to {region}...")
            resp = ec2.copy_image(
                SourceRegion=source_region,
                SourceImageId=source_ami_id,
                Name=f"neo4j-ee-copy-{source_ami_id}",
                Description=f"Copied from {source_ami_id} in {source_region}",
            )
            copied_ami_id = resp["ImageId"]
            print(f"Copied AMI: {copied_ami_id} - waiting for it to become available...")
            _wait_for_ami(ec2, copied_ami_id, region)
            _tag_copied_ami(ec2, copied_ami_id, source_ami_id, source_region)
        ami_id = copied_ami_id
    else:
        ami_id = source_ami_id

    ssm_param_path = f"/neo4j-ee/test/{stack_name}/ami-id"
    print(f"Creating SSM parameter {ssm_param_path} -> {ami_id}...")
    boto3.client("ssm", region_name=region).put_parameter(
        Name=ssm_param_path,
        Type="String",
        Value=ami_id,
        Overwrite=True,
    )

    return AmiInfo(
        ami_id=ami_id,
        source_ami_id=source_ami_id,
        source="local",
        ssm_param_path=ssm_param_path,
        copied_ami_id=copied_ami_id,
    )
