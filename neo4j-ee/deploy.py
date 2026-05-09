#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3"]
# ///

import argparse
import atexit
import json
import os
from pathlib import Path
import random
import secrets
import string
import sys
import time
import urllib.request

import boto3
from botocore.exceptions import ClientError

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_REGION = "us-east-1"
SUPPORTED_REGIONS = [
    "us-east-1", "us-east-2", "us-west-2",
    "eu-west-1", "eu-central-1",
    "ap-southeast-1", "ap-southeast-2",
]
# Mirrors the InstanceType AllowedValues block in templates/neo4j-private
# .template.yaml, neo4j-public.template.yaml, and
# neo4j-private-existing-vpc.template.yaml. Keep these in sync.
INSTANCE_TYPES = [
    "t3.medium",
    "r8i.large",
    "r8i.xlarge",
    "r8i.2xlarge",
    "r8i.4xlarge",
    "r8i.8xlarge",
    "r8i.12xlarge",
    "r8i.16xlarge",
    "r8i.24xlarge",
    "r8i.32xlarge",
    "r8i.48xlarge",
    "r8i.96xlarge",
]
TEMPLATE_MAP = {
    "Private":     "templates/neo4j-private.template.yaml",
    "Public":      "templates/neo4j-public.template.yaml",
    "ExistingVpc": "templates/neo4j-private-existing-vpc.template.yaml",
}


def parse_args():
    p = argparse.ArgumentParser(
        description="Deploy Neo4j Enterprise Edition CloudFormation stack for local testing.",
    )
    p.add_argument(
        "instance_type", nargs="?", default="t3.medium",
        choices=INSTANCE_TYPES, metavar="INSTANCE_TYPE",
        help=(
            "Fully-qualified EC2 instance type (default: t3.medium). "
            "Allowed: t3.medium, r8i.{large,xlarge,2xlarge,4xlarge,"
            "8xlarge,12xlarge,16xlarge,24xlarge,32xlarge,48xlarge,"
            "96xlarge}. Must match the InstanceType AllowedValues "
            "in the template."
        ),
    )
    p.add_argument("--region", dest="region_override", metavar="REGION")
    p.add_argument("--number-of-servers", type=int, default=3, choices=[1, 3])
    p.add_argument("--marketplace", action="store_true")
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate arguments and print the deployment plan without making AWS API calls.",
    )
    p.add_argument(
        "--cert-arn", metavar="ARN", default=None,
        help=(
            "ACM certificate ARN for the NLB TLS listeners on 7473 and 7687. "
            "Auto-detected from the most recently modified .deploy/cert-*.json "
            "(written by certificate.py) when not provided."
        ),
    )
    p.add_argument(
        "--advertised-dns", metavar="DNS", default=None,
        help=(
            "DNS name that resolves to the NLB and matches the ACM cert SAN. "
            "Auto-detected from .deploy/cert-*.json when not provided."
        ),
    )
    p.add_argument("--alert-email", metavar="EMAIL")
    p.add_argument("--mode", default="Private", choices=["Public", "Private", "ExistingVpc"])
    p.add_argument("--name", metavar="NAME", help="Stack name (default: ee-{timestamp}).")
    p.add_argument("--allowed-cidr", metavar="CIDR")
    p.add_argument("--vpc-id", metavar="VPC_ID")
    p.add_argument("--subnet-1", metavar="SUBNET_ID")
    p.add_argument("--subnet-2", metavar="SUBNET_ID", default="")
    p.add_argument("--subnet-3", metavar="SUBNET_ID", default="")
    p.add_argument("--create-vpc-endpoints", default="true", choices=["true", "false"])
    p.add_argument("--existing-endpoint-sg-id", metavar="SG_ID", default="")
    private_dns = p.add_mutually_exclusive_group()
    private_dns.add_argument(
        "--create-private-dns",
        dest="create_private_dns",
        action="store_true",
        help=(
            "For Private or ExistingVpc deployments, create/manage a Route 53 "
            "private DNS record that maps --advertised-dns to the internal NLB. "
            "This is the default for Private mode. "
            "If --private-dns-hosted-zone-id is omitted, the stack creates a "
            "private hosted zone named --private-dns-zone."
        ),
    )
    private_dns.add_argument(
        "--no-create-private-dns",
        dest="create_private_dns",
        action="store_false",
        help=(
            "Do not create Route 53 private DNS. Use this when customer-managed "
            "DNS already resolves --advertised-dns to the NLB."
        ),
    )
    p.set_defaults(create_private_dns=None)
    p.add_argument(
        "--private-dns-zone",
        metavar="ZONE",
        default="",
        help=(
            "Private hosted zone name to create when --create-private-dns is set "
            "and --private-dns-hosted-zone-id is omitted. Defaults to the parent "
            "domain of --advertised-dns, e.g. neo4j.test.local -> test.local."
        ),
    )
    p.add_argument(
        "--private-dns-hosted-zone-id",
        metavar="ZONE_ID",
        default="",
        help=(
            "Existing Route 53 private hosted zone ID to receive the "
            "--advertised-dns alias record when --create-private-dns is set."
        ),
    )
    p.add_argument("--disk-size", type=int, metavar="GB", help="Data volume size in GB (default: 100, min: 100, max: 65536)")
    p.add_argument("--snapshot-id", metavar="SNAPSHOT_ID", help="Snapshot ID to restore Node 1 data volume from (must match --disk-size)")
    p.add_argument(
        "--vpc-file", metavar="PATH",
        help="Path to vpc-*.txt from scripts/create-test-vpc.py. "
             "Auto-detected from .deploy/vpc-*.txt when --mode ExistingVpc and --vpc-id is not provided. "
             "Populates --vpc-id, --subnet-*, --allowed-cidr, --region, and --existing-endpoint-sg-id "
             "from the file; any of those flags override the file values when provided explicitly.",
    )
    return p.parse_args()


def _resolve_cert_file(explicit: str | None, deploy_dir: str) -> str | None:
    if explicit:
        return explicit
    cert_files = sorted(
        Path(deploy_dir).glob("cert-*.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return str(cert_files[0]) if cert_files else None


def _parse_cert_file(path: str) -> dict[str, str]:
    return json.loads(Path(path).read_text())


def _detect_self_signed_cert(
    cert_arn: str,
    advertised_dns: str,
    deploy_dir: str,
) -> bool:
    for cert_file in Path(deploy_dir).glob("cert-*.json"):
        try:
            cert_fields = _parse_cert_file(str(cert_file))
        except (OSError, json.JSONDecodeError):
            continue
        if not cert_fields.get("self_signed", False):
            continue
        if cert_fields.get("cert_arn") == cert_arn:
            return True
        if cert_fields.get("domain_name") == advertised_dns:
            return True
    return False


def _certificate_type(cert_arn: str, region: str) -> str:
    if not cert_arn:
        return ""
    try:
        acm = boto3.client("acm", region_name=region)
        cert = acm.describe_certificate(CertificateArn=cert_arn)["Certificate"]
    except ClientError:
        return ""
    return cert.get("Type", "")


def _resolve_vpc_file(explicit: str | None, deploy_dir: str) -> str | None:
    if explicit:
        return explicit
    vpc_files = sorted(
        Path(deploy_dir).glob("vpc-*.txt"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return str(vpc_files[0]) if vpc_files else None


def _parse_vpc_file(path: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in Path(path).read_text().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            fields[k.strip()] = v.strip()
    return fields


def generate_password():
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(32))


def detect_public_ip():
    try:
        with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=5) as r:
            return r.read().decode().strip()
    except Exception:
        return None


def derive_private_dns_zone(advertised_dns: str) -> str:
    labels = advertised_dns.rstrip(".").split(".")
    if len(labels) < 2:
        raise ValueError(
            "--create-private-dns requires --private-dns-zone when "
            "--advertised-dns is not a subdomain."
        )
    return ".".join(labels[1:])


def build_cfn_params(
    args: argparse.Namespace,
    password: str,
    allowed_cidr: str,
    ssm_param_path: str,
) -> list[dict[str, str]]:
    params = [
        {"ParameterKey": "Password", "ParameterValue": password},
        {
            "ParameterKey": "NumberOfServers",
            "ParameterValue": str(args.number_of_servers),
        },
        {"ParameterKey": "InstanceType", "ParameterValue": args.instance_type},
        {"ParameterKey": "AllowedCIDR", "ParameterValue": allowed_cidr},
        {"ParameterKey": "CertificateArn", "ParameterValue": args.cert_arn},
        {"ParameterKey": "AdvertisedDNS", "ParameterValue": args.advertised_dns},
        {"ParameterKey": "InstallGDS", "ParameterValue": "true"},
    ]
    if args.mode in ("Private", "ExistingVpc"):
        params += [
            {
                "ParameterKey": "CreatePrivateDns",
                "ParameterValue": "true" if args.create_private_dns else "false",
            },
            {"ParameterKey": "PrivateDnsZoneName", "ParameterValue": args.private_dns_zone},
            {
                "ParameterKey": "PrivateDnsHostedZoneId",
                "ParameterValue": args.private_dns_hosted_zone_id,
            },
        ]
    if ssm_param_path:
        params.append({"ParameterKey": "ImageId", "ParameterValue": ssm_param_path})
    if args.alert_email:
        params.append({"ParameterKey": "AlertEmail", "ParameterValue": args.alert_email})
    if args.disk_size is not None:
        params.append(
            {"ParameterKey": "DataDiskSize", "ParameterValue": str(args.disk_size)}
        )
    if args.snapshot_id:
        params.append(
            {"ParameterKey": "Node1SnapshotId", "ParameterValue": args.snapshot_id}
        )
    if args.mode == "ExistingVpc":
        params += [
            {"ParameterKey": "VpcId", "ParameterValue": args.vpc_id},
            {"ParameterKey": "PrivateSubnet1Id", "ParameterValue": args.subnet_1},
            {"ParameterKey": "PrivateSubnet2Id", "ParameterValue": args.subnet_2},
            {"ParameterKey": "PrivateSubnet3Id", "ParameterValue": args.subnet_3},
            {
                "ParameterKey": "CreateVpcEndpoints",
                "ParameterValue": args.create_vpc_endpoints,
            },
        ]
        if args.existing_endpoint_sg_id:
            params.append(
                {
                    "ParameterKey": "ExistingEndpointSgId",
                    "ParameterValue": args.existing_endpoint_sg_id,
                }
            )
    return params


def main():
    os.environ.setdefault("AWS_PROFILE", "default")
    args = parse_args()
    cert_self_signed = False

    if args.mode == "ExistingVpc" and not args.vpc_id:
        deploy_dir = os.path.join(SCRIPT_DIR, ".deploy")
        vpc_file_path = _resolve_vpc_file(args.vpc_file, deploy_dir)
        if not vpc_file_path:
            sys.exit(
                "ERROR: --mode ExistingVpc requires --vpc-id and --subnet-1, "
                "or a vpc-*.txt file from scripts/create-test-vpc.py in .deploy/"
            )
        vpc_fields = _parse_vpc_file(vpc_file_path)
        print(f"VPC config from: {os.path.basename(vpc_file_path)}")
        args.vpc_id = vpc_fields.get("VpcId", "")
        if not args.subnet_1:
            args.subnet_1 = vpc_fields.get("Subnet1Id", "")
        if not args.subnet_2:
            args.subnet_2 = vpc_fields.get("Subnet2Id", "")
        if not args.subnet_3:
            args.subnet_3 = vpc_fields.get("Subnet3Id", "")
        if not args.allowed_cidr:
            args.allowed_cidr = vpc_fields.get("VpcCidr", "")
        if not args.region_override:
            args.region_override = vpc_fields.get("Region", "")
        if not args.existing_endpoint_sg_id and "EndpointSgId" in vpc_fields:
            args.existing_endpoint_sg_id = vpc_fields["EndpointSgId"]

    if args.mode == "ExistingVpc":
        if not args.vpc_id or not args.subnet_1:
            sys.exit("ERROR: --mode ExistingVpc requires --vpc-id and --subnet-1 (--subnet-2 and --subnet-3 required for 3-node).")
        if args.number_of_servers == 3 and not (args.subnet_2 and args.subnet_3):
            sys.exit("ERROR: --mode ExistingVpc with 3 servers requires --subnet-2 and --subnet-3.")
        if args.create_vpc_endpoints == "false" and not args.existing_endpoint_sg_id:
            sys.exit("ERROR: --existing-endpoint-sg-id is required when --create-vpc-endpoints false")

    if not args.cert_arn or not args.advertised_dns:
        deploy_dir = os.path.join(SCRIPT_DIR, ".deploy")
        cert_file_path = _resolve_cert_file(None, deploy_dir)
        if cert_file_path:
            cert_fields = _parse_cert_file(cert_file_path)
            print(f"Cert config from: {os.path.basename(cert_file_path)}")
            if not args.cert_arn:
                args.cert_arn = cert_fields.get("cert_arn", "")
            if not args.advertised_dns:
                args.advertised_dns = cert_fields.get("domain_name", "")
            cert_self_signed = bool(cert_fields.get("self_signed", False))
            if not args.region_override:
                args.region_override = cert_fields.get("region", "")

    if not args.cert_arn:
        sys.exit(
            "ERROR: --cert-arn is required (or run certificate.py first to write .deploy/cert-*.json)."
        )
    if not args.advertised_dns:
        sys.exit(
            "ERROR: --advertised-dns is required (or run certificate.py first to write .deploy/cert-*.json)."
        )
    deploy_dir = os.path.join(SCRIPT_DIR, ".deploy")
    if not cert_self_signed:
        cert_self_signed = _detect_self_signed_cert(
            args.cert_arn,
            args.advertised_dns,
            deploy_dir,
        )
    if args.create_private_dns is None:
        args.create_private_dns = args.mode == "Private"
    if args.create_private_dns:
        if args.mode == "Public":
            sys.exit("ERROR: --create-private-dns is only valid for Private or ExistingVpc deployments.")
        if args.private_dns_hosted_zone_id.startswith("/hostedzone/"):
            args.private_dns_hosted_zone_id = args.private_dns_hosted_zone_id.split("/", 2)[-1]
        if not args.private_dns_zone and not args.private_dns_hosted_zone_id:
            try:
                args.private_dns_zone = derive_private_dns_zone(args.advertised_dns)
            except ValueError as exc:
                sys.exit(f"ERROR: {exc}")
        if args.private_dns_zone and not args.advertised_dns.rstrip(".").endswith(args.private_dns_zone.rstrip(".")):
            sys.exit(
                "ERROR: --advertised-dns must be inside --private-dns-zone "
                "when --create-private-dns creates a hosted zone."
            )

    instance_type = args.instance_type

    if args.allowed_cidr:
        allowed_cidr = args.allowed_cidr
    elif args.mode in ("Private", "ExistingVpc"):
        allowed_cidr = "10.0.0.0/16"
    else:
        ip = detect_public_ip()
        if not ip:
            sys.exit("ERROR: Could not detect public IP. Pass --allowed-cidr explicitly.")
        allowed_cidr = f"{ip}/32"

    region = args.region_override or random.choice(SUPPORTED_REGIONS)
    ts = int(time.time())
    stack_name = args.name if args.name else f"ee-{ts}"
    cert_type = "" if args.dry_run else _certificate_type(args.cert_arn, region)

    # NLB target group names are "{stack_name}-https-tg" (the longest suffix).
    # AWS enforces a 32-character limit on target group names.
    _MAX_TG_SUFFIX = len("-https-tg")
    if len(stack_name) + _MAX_TG_SUFFIX > 32:
        max_name_len = 32 - _MAX_TG_SUFFIX
        sys.exit(
            f"ERROR: --name '{args.name}' is too long. "
            f"Stack name '{stack_name}' would produce NLB target group names "
            f"exceeding AWS's 32-character limit. "
            f"Shorten the stack name to {max_name_len} characters or fewer."
        )

    password = generate_password()

    if args.dry_run:
        dry_run_ssm_param_path = (
            "" if args.marketplace else f"/neo4j-ee/test/{stack_name}/ami-id"
        )
        cfn_params = build_cfn_params(
            args, password, allowed_cidr, dry_run_ssm_param_path
        )
        print()
        print("=============================================")
        print("  Neo4j EE Deployment Dry Run")
        print("=============================================")
        print(f"  Stack:          {stack_name}")
        print(f"  Region:         {region}")
        print(f"  Instance:       {instance_type}")
        print(f"  Servers:        {args.number_of_servers}")
        print(f"  Mode:           {args.mode}")
        print(f"  Template:       {TEMPLATE_MAP[args.mode]}")
        print(f"  AllowedCIDR:    {allowed_cidr}")
        print(f"  CertificateArn: {args.cert_arn}")
        print(f"  AdvertisedDNS:  {args.advertised_dns}")
        if cert_self_signed:
            print("  CertTrust:      self-signed test certificate")
        if args.mode in ("Private", "ExistingVpc"):
            print(f"  PrivateDNS:     {'create/manage' if args.create_private_dns else 'disabled'}")
            if args.create_private_dns:
                if args.private_dns_hosted_zone_id:
                    print(f"  PrivateDNSZone: {args.private_dns_hosted_zone_id} (existing)")
                else:
                    print(f"  PrivateDNSZone: {args.private_dns_zone} (new)")
        print(f"  AMI source:     {'marketplace' if args.marketplace else 'local'}")
        if not args.marketplace:
            print("  AMI check:      skipped; actual deploy requires marketplace/ami-id.txt")
            print(f"  ImageId param:  {dry_run_ssm_param_path}")
        if args.alert_email:
            print(f"  Alert email:    {args.alert_email}")
        print("=============================================")
        print()
        print("CloudFormation parameters:")
        for param in cfn_params:
            key = param["ParameterKey"]
            value = "<generated>" if key == "Password" else param["ParameterValue"]
            print(f"  {key}: {value}")
        print()
        print("Dry run complete. No AWS API calls were made.")
        return

    cleanup_state = {
        "cfn_bucket": None,
        "copied_ami_id": None,
    }

    def cleanup():
        if cleanup_state["cfn_bucket"]:
            bucket = cleanup_state["cfn_bucket"]
            print(f"Cleaning up temporary S3 bucket {bucket}...")
            try:
                s3 = boto3.client("s3", region_name=region)
                paginator = s3.get_paginator("list_objects_v2")
                for page in paginator.paginate(Bucket=bucket):
                    for obj in page.get("Contents", []):
                        s3.delete_object(Bucket=bucket, Key=obj["Key"])
                s3.delete_bucket(Bucket=bucket)
            except Exception as e:
                print(f"  Warning: could not fully clean up S3 bucket {bucket}: {e}")

    atexit.register(cleanup)

    ssm_param_path = ""
    ami_id = ""
    source_ami_id = ""
    ami_source = "marketplace"

    if not args.marketplace:
        ami_source = "local"
        ami_id_file = os.path.join(SCRIPT_DIR, "marketplace", "ami-id.txt")
        if not os.path.exists(ami_id_file):
            sys.exit(
                f"ERROR: {ami_id_file} not found. Run marketplace/create-ami.sh first,\n"
                "       or use --marketplace to deploy from the live Marketplace listing."
            )
        source_ami_id = Path(ami_id_file).read_text().strip()
        ec2 = boto3.client("ec2", region_name=region)

        if region != SOURCE_REGION:
            existing = ec2.describe_images(
                Owners=["self"],
                Filters=[{"Name": "description", "Values": [f"Copied from {source_ami_id} in {SOURCE_REGION}"]}],
            )["Images"]
            available = sorted(
                [img for img in existing if img["State"] == "available"],
                key=lambda img: img["CreationDate"], reverse=True,
            )
            pending = [img for img in existing if img["State"] == "pending"]
            if available:
                copied_ami_id = available[0]["ImageId"]
                print(f"Reusing existing copied AMI {copied_ami_id} in {region}.")
                cleanup_state["copied_ami_id"] = copied_ami_id
            elif pending:
                copied_ami_id = pending[0]["ImageId"]
                print(f"Found in-progress AMI copy {copied_ami_id} in {region} — waiting for it to become available...")
                ec2.get_waiter("image_available").wait(
                    ImageIds=[copied_ami_id],
                    WaiterConfig={"Delay": 30, "MaxAttempts": 60},
                )
                print(f"AMI available in {region}.")
                cleanup_state["copied_ami_id"] = copied_ami_id
            else:
                print(f"Copying AMI {source_ami_id} from {SOURCE_REGION} to {region}...")
                resp = ec2.copy_image(
                    SourceRegion=SOURCE_REGION,
                    SourceImageId=source_ami_id,
                    Name=f"neo4j-ee-copy-{source_ami_id}",
                    Description=f"Copied from {source_ami_id} in {SOURCE_REGION}",
                )
                copied_ami_id = resp["ImageId"]
                cleanup_state["copied_ami_id"] = copied_ami_id
                print(f"Copied AMI: {copied_ami_id} — waiting for it to become available...")
                ec2.get_waiter("image_available").wait(
                    ImageIds=[copied_ami_id],
                    WaiterConfig={"Delay": 30, "MaxAttempts": 60},
                )
                print(f"AMI available in {region}.")
            ami_id = copied_ami_id
        else:
            ami_id = source_ami_id

        ssm_param_path = f"/neo4j-ee/test/{stack_name}/ami-id"
        print(f"Creating SSM parameter {ssm_param_path} -> {ami_id}...")
        boto3.client("ssm", region_name=region).put_parameter(
            Name=ssm_param_path, Type="String", Value=ami_id, Overwrite=True,
        )

    print()
    print("=============================================")
    print("  Neo4j EE Deployment")
    print("=============================================")
    print(f"  Stack:          {stack_name}")
    print(f"  Region:         {region}")
    print(f"  Instance:       {instance_type}")
    print(f"  Servers:        {args.number_of_servers}")
    print(f"  Mode:           {args.mode}")
    print(f"  AllowedCIDR:    {allowed_cidr}")
    print(f"  CertificateArn: {args.cert_arn}")
    if cert_type:
        print(f"  CertificateType: {cert_type}")
    print(f"  AdvertisedDNS:  {args.advertised_dns}")
    if cert_self_signed:
        print("  CertTrust:      self-signed test certificate")
    if args.mode in ("Private", "ExistingVpc"):
        print(f"  PrivateDNS:     {'create/manage' if args.create_private_dns else 'disabled'}")
        if args.create_private_dns:
            if args.private_dns_hosted_zone_id:
                print(f"  PrivateDNSZone: {args.private_dns_hosted_zone_id} (existing)")
            else:
                print(f"  PrivateDNSZone: {args.private_dns_zone} (new)")
    print(f"  AMI source:     {ami_source}")
    if not args.marketplace:
        print(f"  AMI:            {ami_id}")
        if cleanup_state["copied_ami_id"]:
            print(f"  AMI original:   {source_ami_id} (copied from {SOURCE_REGION})")
    if args.alert_email:
        print(f"  Alert email:    {args.alert_email}")
    print("=============================================")
    print()

    # Upload template to S3 (template exceeds 51,200-byte inline CFN limit)
    account_id = boto3.client("sts", region_name=region).get_caller_identity()["Account"]
    bucket_name = f"neo4j-ee-cfn-{account_id}-{region}-{ts}"
    print(f"Uploading template to s3://{bucket_name}...")
    s3 = boto3.client("s3", region_name=region)
    if region == "us-east-1":
        s3.create_bucket(Bucket=bucket_name)
    else:
        s3.create_bucket(
            Bucket=bucket_name,
            CreateBucketConfiguration={"LocationConstraint": region},
        )
    cleanup_state["cfn_bucket"] = bucket_name
    template_file = TEMPLATE_MAP[args.mode]
    template_key = os.path.basename(template_file)
    s3.upload_file(os.path.join(SCRIPT_DIR, template_file), bucket_name, template_key)
    template_url = f"https://{bucket_name}.s3.{region}.amazonaws.com/{template_key}"

    cfn_params = build_cfn_params(args, password, allowed_cidr, ssm_param_path)

    cfn = boto3.client("cloudformation", region_name=region)
    print(f"Creating stack {stack_name}...")
    cfn.create_stack(
        StackName=stack_name,
        TemplateURL=template_url,
        Capabilities=["CAPABILITY_IAM"],
        DisableRollback=True,
        Parameters=cfn_params,
    )
    print("Waiting for stack to complete (this takes a few minutes)...")
    cfn.get_waiter("stack_create_complete").wait(
        StackName=stack_name,
        WaiterConfig={"Delay": 15, "MaxAttempts": 120},
    )

    deploy_dir = os.path.join(SCRIPT_DIR, ".deploy")
    os.makedirs(deploy_dir, exist_ok=True)
    outputs_file = os.path.join(deploy_dir, f"{stack_name}.txt")

    print(f"Stack created. Writing outputs to {outputs_file}...")
    stack_data = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]

    lines = [
        f"{o['OutputKey']:<20} = {o['OutputValue']}"
        for o in stack_data.get("Outputs", [])
    ]
    extra = [
        ("StackName", stack_name),
        ("Region", region),
        ("Password", password),
        ("NumberOfServers", str(args.number_of_servers)),
        ("InstanceType", instance_type),
        ("Edition", "ee"),
        ("DeploymentMode", args.mode),
        ("AmiSource", ami_source),
        ("InstallAPOC", "yes"),
        ("InstallGDS", "true"),
    ]
    if args.alert_email:
        extra.append(("AlertEmail", args.alert_email))
    if args.mode == "ExistingVpc":
        extra.append(("CreateVpcEndpoints", args.create_vpc_endpoints))
        if args.existing_endpoint_sg_id:
            extra.append(("ExistingEndpointSgId", args.existing_endpoint_sg_id))
    if args.mode in ("Private", "ExistingVpc"):
        extra.append(("CreatePrivateDns", "true" if args.create_private_dns else "false"))
        if args.create_private_dns:
            if args.private_dns_zone:
                extra.append(("PrivateDnsZoneName", args.private_dns_zone))
            if args.private_dns_hosted_zone_id:
                extra.append(("PrivateDnsHostedZoneId", args.private_dns_hosted_zone_id))
    if ssm_param_path:
        extra.extend([("SSMParamPath", ssm_param_path), ("AmiId", ami_id)])
    if cleanup_state["copied_ami_id"]:
        extra.extend([("CopiedAmiId", cleanup_state["copied_ami_id"]), ("SourceRegion", SOURCE_REGION)])
    extra.append(("CertificateArn", args.cert_arn))
    if cert_type:
        extra.append(("CertificateType", cert_type))
    extra.append(("AdvertisedDNS", args.advertised_dns))
    if cert_self_signed:
        extra.append(("SelfSignedCertificate", "true"))
    extra.append(("StackID", stack_data["StackId"]))

    lines += [f"{k:<20} = {v}" for k, v in extra]
    output = "\n".join(lines) + "\n"
    print(output, end="")
    with open(outputs_file, "w") as f:
        f.write(output)

    print()
    print(f"Outputs saved to {outputs_file}")
    print()
    print(f"To test:      cd ../test_neo4j && uv run test-neo4j --edition ee --stack {stack_name}")
    print(f"To tear down: ./teardown.sh {stack_name}")


if __name__ == "__main__":
    main()
