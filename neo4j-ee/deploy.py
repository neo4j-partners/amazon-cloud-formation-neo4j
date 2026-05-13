#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3", "cryptography"]
# ///

import argparse
import atexit
import datetime
import json
import os
from pathlib import Path
import random
import secrets
import string
import sys
import time
import urllib.parse
import urllib.request

import boto3
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

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
LOCAL_LICENSE_DIR = Path(SCRIPT_DIR) / ".licenses"
LOCAL_LICENSE_FILES = {
    "bloom": LOCAL_LICENSE_DIR / "bloom.license",
    "gds": LOCAL_LICENSE_DIR / "gds.license",
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
    p.add_argument("--tls", action="store_true")
    p.add_argument("--alert-email", metavar="EMAIL")
    p.add_argument("--mode", default="Private", choices=["Public", "Private", "ExistingVpc"])
    p.add_argument("--allowed-cidr", metavar="CIDR")
    p.add_argument("--vpc-id", metavar="VPC_ID")
    p.add_argument("--subnet-1", metavar="SUBNET_ID")
    p.add_argument("--subnet-2", metavar="SUBNET_ID", default="")
    p.add_argument("--subnet-3", metavar="SUBNET_ID", default="")
    p.add_argument("--create-vpc-endpoints", default="true", choices=["true", "false"])
    p.add_argument("--existing-endpoint-sg-id", metavar="SG_ID", default="")
    p.add_argument("--disk-size", type=int, metavar="GB", help="Data volume size in GB (default: 100, min: 100, max: 65536)")
    p.add_argument("--snapshot-id", metavar="SNAPSHOT_ID", help="Snapshot ID to restore Node 1 data volume from (must match --disk-size)")
    p.add_argument("--no-bloom", action="store_true",
                   help="Skip the Bloom plugin install (sets InstallBloom=false). Default: install Bloom.")
    p.add_argument("--no-gds", action="store_true",
                   help="Skip the GDS plugin install (sets InstallGDS=false). Default: install GDS.")
    p.add_argument(
        "--bloom-license-secret-id", metavar="SECRET",
        help="Secrets Manager secret name or ARN holding the Bloom licence. "
             "Resolved to an ARN and passed as BloomLicenseSecretArn; UserData "
             "fetches and installs the licence on first boot and after instance "
             "replacement. Required when Bloom is installed (default on); pass "
             "--no-bloom to skip, or place a licence at .licenses/bloom.license "
             "to auto-upload it.",
    )
    p.add_argument(
        "--gds-license-secret-id", metavar="SECRET",
        help="Secrets Manager secret name or ARN holding the GDS Enterprise licence. "
             "Resolved to an ARN and passed as GdsLicenseSecretArn; UserData "
             "fetches and installs the licence on first boot and after instance "
             "replacement. Required when GDS is installed (default on); pass "
             "--no-gds to skip, or place a licence at .licenses/gds.license "
             "to auto-upload it.",
    )
    p.add_argument(
        "--no-local-licenses", action="store_true",
        help="Do not auto-upload neo4j-ee/.licenses/*.license files when "
             "matching --*-license-secret-id arguments are omitted.",
    )
    p.add_argument(
        "--vpc-file", metavar="PATH",
        help="Path to vpc-*.txt from scripts/create-test-vpc.py. "
             "Auto-detected from .deploy/vpc-*.txt when --mode ExistingVpc and --vpc-id is not provided. "
             "Populates --vpc-id, --subnet-*, --allowed-cidr, --region, and --existing-endpoint-sg-id "
             "from the file; any of those flags override the file values when provided explicitly.",
    )
    return p.parse_args()


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
    return "".join(secrets.choice(alphabet) for _ in range(16))


def detect_public_ip():
    try:
        with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=5) as r:
            return r.read().decode().strip()
    except Exception:
        return None


def generate_tls_cert(nlb_dns):
    key = rsa.generate_private_key(public_exponent=65537, key_size=4096)
    now = datetime.datetime.now(datetime.timezone.utc)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "neo4j-bolt")])
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=365))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName(nlb_dns)]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    cert_pem = cert.public_bytes(serialization.Encoding.PEM).decode()
    key_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ).decode()
    return cert_pem, key_pem


def describe_stack_outputs(cfn, stack_name: str) -> dict[str, str]:
    stack = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]
    return {
        output["OutputKey"]: output["OutputValue"]
        for output in stack.get("Outputs", [])
    }


def _create_local_license_secret(sm, stack_name: str, product: str, path: Path) -> str:
    license_text = path.read_text().strip()
    if not license_text:
        sys.exit(f"ERROR: Local {product} licence file is empty: {path}")

    secret_name = f"neo4j/{stack_name}/licenses/{product}"
    response = sm.create_secret(
        Name=secret_name,
        Description=(
            f"Temporary Neo4j {product.upper()} licence for deploy.py stack "
            f"{stack_name}. Created from {path.name}."
        ),
        SecretString=license_text,
        Tags=[
            {"Key": "StackName", "Value": stack_name},
            {"Key": "CreatedBy", "Value": "neo4j-ee/deploy.py"},
            {"Key": "LicenseProduct", "Value": product},
        ],
    )
    return response["ARN"]


def resolve_license_secret_arns(args, region: str, stack_name: str):
    """Resolve explicit or local licence inputs to Secrets Manager ARNs.

    The ARNs are passed to CloudFormation as BloomLicenseSecretArn /
    GdsLicenseSecretArn. The stack's instance role is granted
    secretsmanager:GetSecretValue scoped to those exact ARNs (see iam.yaml),
    and UserData fetches them on first boot and on instance replacement.
    """
    sm = boto3.client("secretsmanager", region_name=region)
    bloom_input = args.bloom_license_secret_id
    gds_input = args.gds_license_secret_id
    created_secret_arns: list[str] = []

    if not args.no_local_licenses:
        local_specs = [
            ("bloom", LOCAL_LICENSE_FILES["bloom"], bloom_input, not args.no_bloom),
            ("gds", LOCAL_LICENSE_FILES["gds"], gds_input, not args.no_gds),
        ]
        for product, path, explicit_secret, install_enabled in local_specs:
            if explicit_secret or not path.exists():
                continue
            if not install_enabled:
                print(f"Local {product.upper()} licence present but ignored because the plugin is disabled.")
                continue
            secret_arn = _create_local_license_secret(sm, stack_name, product, path)
            created_secret_arns.append(secret_arn)
            if product == "bloom":
                bloom_input = secret_arn
            else:
                gds_input = secret_arn
            print(f"Local {product.upper()} licence uploaded to Secrets Manager: {secret_arn}")

    def _to_arn(secret_input: str | None) -> str:
        if not secret_input:
            return ""
        return sm.describe_secret(SecretId=secret_input)["ARN"]

    return _to_arn(bloom_input), _to_arn(gds_input), created_secret_arns


def nlb_dns_from_outputs(cfn, stack_name: str) -> str:
    outputs = describe_stack_outputs(cfn, stack_name)
    if outputs.get("Neo4jInternalDNS"):
        return outputs["Neo4jInternalDNS"]

    for key in ("Neo4jURI", "Neo4jBrowserURL"):
        value = outputs.get(key, "")
        if not value:
            continue
        hostname = urllib.parse.urlparse(value).hostname
        if hostname:
            return hostname

    sys.exit(
        "ERROR: Could not resolve the NLB DNS name from stack outputs. "
        "Expected Neo4jInternalDNS, Neo4jURI, or Neo4jBrowserURL."
    )


def main():
    os.environ.setdefault("AWS_PROFILE", "default")
    args = parse_args()

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
    stack_name = f"test-ee-{ts}"
    password = generate_password()
    install_bloom = "false" if getattr(args, "no_bloom", False) else "true"
    install_gds = "false" if getattr(args, "no_gds", False) else "true"

    cleanup_state = {
        "cfn_bucket": None,
        "copied_ami_id": None,
        "tls_secret_arn": None,
        "license_secret_arns": [],
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
        if cleanup_state["tls_secret_arn"]:
            arn = cleanup_state["tls_secret_arn"]
            print(f"\nCleaning up TLS secret {arn}...")
            try:
                boto3.client("secretsmanager", region_name=region).delete_secret(
                    SecretId=arn, ForceDeleteWithoutRecovery=True
                )
            except Exception as e:
                print(f"  Warning: could not delete TLS secret: {e}")
        for arn in cleanup_state["license_secret_arns"]:
            print(f"\nCleaning up local licence secret {arn}...")
            try:
                boto3.client("secretsmanager", region_name=region).delete_secret(
                    SecretId=arn, ForceDeleteWithoutRecovery=True
                )
            except Exception as e:
                print(f"  Warning: could not delete licence secret: {e}")

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
            # Tag the copy with the source AMI/region so downstream tooling
            # (the G6 build-mode tag check, future audits) does not have to
            # parse the Description string. copy_image does not propagate
            # source tags, so we set them explicitly after the copy becomes
            # available. Best-effort: log and continue if tagging fails.
            try:
                ec2.create_tags(
                    Resources=[copied_ami_id],
                    Tags=[
                        {"Key": "SourceAmiId", "Value": source_ami_id},
                        {"Key": "SourceRegion", "Value": SOURCE_REGION},
                    ],
                )
            except Exception as exc:
                print(f"Warning: could not tag copied AMI {copied_ami_id}: {exc}")
            ami_id = copied_ami_id
        else:
            ami_id = source_ami_id

        ssm_param_path = f"/neo4j-ee/test/{stack_name}/ami-id"
        print(f"Creating SSM parameter {ssm_param_path} -> {ami_id}...")
        boto3.client("ssm", region_name=region).put_parameter(
            Name=ssm_param_path, Type="String", Value=ami_id, Overwrite=True,
        )

    bloom_license_secret_arn, gds_license_secret_arn, created_license_secret_arns = (
        resolve_license_secret_arns(args, region, stack_name)
    )
    cleanup_state["license_secret_arns"] = created_license_secret_arns

    # Fail early: the template now requires matching license ARNs whenever a
    # plugin is installed (enforced by AWS::CloudFormation::Rules and mirrored
    # by UserData fail-fast guards). Surface the
    # missing licence here before we create the stack so the operator gets a
    # clean error instead of a CloudFormation rollback.
    if install_bloom == "true" and not bloom_license_secret_arn:
        sys.exit(
            "ERROR: InstallBloom=true requires a Bloom licence. Provide one of:\n"
            "  --bloom-license-secret-id <name|arn>  (existing Secrets Manager secret)\n"
            "  place a licence at .licenses/bloom.license  (auto-uploaded)\n"
            "  pass --no-bloom  (skip installing Bloom)"
        )
    if install_gds == "true" and not gds_license_secret_arn:
        sys.exit(
            "ERROR: InstallGDS=true requires a GDS licence. Provide one of:\n"
            "  --gds-license-secret-id <name|arn>  (existing Secrets Manager secret)\n"
            "  place a licence at .licenses/gds.license  (auto-uploaded)\n"
            "  pass --no-gds  (skip installing GDS)"
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
    print(f"  TLS:            {args.tls}")
    print(f"  AMI source:     {ami_source}")
    print(f"  Install Bloom:  {install_bloom}")
    print(f"  Install GDS:    {install_gds}")
    print(f"  Bloom licence:  {'yes' if bloom_license_secret_arn else 'no'}")
    print(f"  GDS licence:    {'yes' if gds_license_secret_arn else 'no'}")
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

    cfn_params = [
        {"ParameterKey": "Password", "ParameterValue": password},
        {"ParameterKey": "NumberOfServers", "ParameterValue": str(args.number_of_servers)},
        {"ParameterKey": "InstanceType", "ParameterValue": instance_type},
        {"ParameterKey": "AllowedCIDR", "ParameterValue": allowed_cidr},
        {"ParameterKey": "InstallGDS", "ParameterValue": install_gds},
        {"ParameterKey": "InstallBloom", "ParameterValue": install_bloom},
        {"ParameterKey": "BloomLicenseSecretArn", "ParameterValue": bloom_license_secret_arn},
        {"ParameterKey": "GdsLicenseSecretArn", "ParameterValue": gds_license_secret_arn},
    ]
    if ssm_param_path:
        cfn_params.append({"ParameterKey": "ImageId", "ParameterValue": ssm_param_path})
    if args.alert_email:
        cfn_params.append({"ParameterKey": "AlertEmail", "ParameterValue": args.alert_email})
    if args.disk_size is not None:
        cfn_params.append({"ParameterKey": "DataDiskSize", "ParameterValue": str(args.disk_size)})
    if args.snapshot_id:
        cfn_params.append({"ParameterKey": "Node1SnapshotId", "ParameterValue": args.snapshot_id})
    if args.mode == "ExistingVpc":
        cfn_params += [
            {"ParameterKey": "VpcId",            "ParameterValue": args.vpc_id},
            {"ParameterKey": "PrivateSubnet1Id", "ParameterValue": args.subnet_1},
            {"ParameterKey": "PrivateSubnet2Id", "ParameterValue": args.subnet_2},
            {"ParameterKey": "PrivateSubnet3Id", "ParameterValue": args.subnet_3},
            {"ParameterKey": "CreateVpcEndpoints", "ParameterValue": args.create_vpc_endpoints},
        ]
        if args.existing_endpoint_sg_id:
            cfn_params.append({"ParameterKey": "ExistingEndpointSgId", "ParameterValue": args.existing_endpoint_sg_id})

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

    bolt_tls_secret_arn = ""
    if args.tls:
        print()
        print("--- TLS Phase: generating self-signed cert and updating stack ---")

        nlb_dns = nlb_dns_from_outputs(cfn, stack_name)
        print(f"NLB DNS: {nlb_dns}")

        cert_pem, key_pem = generate_tls_cert(nlb_dns)
        print(f"Self-signed cert generated (SAN: DNS:{nlb_dns})")

        bolt_tls_secret_arn = boto3.client("secretsmanager", region_name=region).create_secret(
            Name=f"neo4j-bolt-tls-{stack_name}",
            SecretString=json.dumps({"certificate": cert_pem, "private_key": key_pem}),
        )["ARN"]
        cleanup_state["tls_secret_arn"] = bolt_tls_secret_arn
        print(f"Secrets Manager secret created: {bolt_tls_secret_arn}")

        print("Updating stack with BoltCertificateSecretArn...")
        existing_params = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]["Parameters"]
        update_params = [
            {"ParameterKey": p["ParameterKey"], "UsePreviousValue": True}
            for p in existing_params
            if p["ParameterKey"] != "BoltCertificateSecretArn"
        ]
        update_params.append({
            "ParameterKey": "BoltCertificateSecretArn",
            "ParameterValue": bolt_tls_secret_arn,
        })
        cfn.update_stack(
            StackName=stack_name,
            TemplateURL=template_url,
            Capabilities=["CAPABILITY_IAM"],
            Parameters=update_params,
        )
        print("Waiting for stack update to complete...")
        cfn.get_waiter("stack_update_complete").wait(
            StackName=stack_name,
            WaiterConfig={"Delay": 15, "MaxAttempts": 120},
        )
        print("Stack updated.")

        asg = boto3.client("autoscaling", region_name=region)
        refresh_ids = {}
        for i in range(1, args.number_of_servers + 1):
            asg_name = cfn.describe_stack_resource(
                StackName=stack_name,
                LogicalResourceId=f"Neo4jNode{i}ASG",
            )["StackResourceDetail"]["PhysicalResourceId"]
            print(f"Starting instance refresh on ASG: {asg_name}")
            refresh_id = asg.start_instance_refresh(
                AutoScalingGroupName=asg_name,
                Preferences={"MinHealthyPercentage": 0, "InstanceWarmup": 300},
            )["InstanceRefreshId"]
            print(f"Instance refresh started: {refresh_id}")
            refresh_ids[asg_name] = refresh_id
        print("Waiting for instance refresh to complete (EE 3-node: ~5-10 min)...")
        _REFRESH_TERMINAL_FAIL = {"Failed", "Cancelled", "RollbackSuccessful", "RollbackFailed"}
        while refresh_ids:
            time.sleep(60)
            for asg_name, refresh_id in list(refresh_ids.items()):
                status = asg.describe_instance_refreshes(
                    AutoScalingGroupName=asg_name,
                    InstanceRefreshIds=[refresh_id],
                )["InstanceRefreshes"][0]["Status"]
                print(f"  {asg_name}: {status}")
                if status == "Successful":
                    print(f"Instance refresh complete for {asg_name}.")
                    del refresh_ids[asg_name]
                elif status in _REFRESH_TERMINAL_FAIL:
                    sys.exit(f"ERROR: Instance refresh {status} for {asg_name}.")

        cleanup_state["tls_secret_arn"] = None  # persist for teardown.sh

        print()
        print(
            "TLS enabled on Bolt. Local tools and the sample app use +ssc "
            "when BoltTlsSecretArn is present."
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
        ("InstallGDS", install_gds),
        ("InstallBloom", install_bloom),
        # The test runner uses this to gate check_bloom_plugin_loaded and the
        # G3 conf-key audit's Bloom-only expectations. Derived from the
        # InstallBloom CFN parameter so a deploy with --no-bloom does not
        # incorrectly assert Bloom is present.
        ("BloomExpected", "yes" if install_bloom == "true" else "no"),
    ]
    if args.alert_email:
        extra.append(("AlertEmail", args.alert_email))
    if args.mode == "ExistingVpc":
        extra.append(("CreateVpcEndpoints", args.create_vpc_endpoints))
        if args.existing_endpoint_sg_id:
            extra.append(("ExistingEndpointSgId", args.existing_endpoint_sg_id))
    if ssm_param_path:
        extra.extend([("SSMParamPath", ssm_param_path), ("AmiId", ami_id)])
    if cleanup_state["copied_ami_id"]:
        extra.extend([("CopiedAmiId", cleanup_state["copied_ami_id"]), ("SourceRegion", SOURCE_REGION)])
    if bolt_tls_secret_arn:
        extra.append(("BoltTlsSecretArn", bolt_tls_secret_arn))
    # Recorded so test_neo4j can detect a licensed deploy and run the Bloom/GDS
    # Enterprise-mode assertions; absent fields mean the plugin was not installed.
    if bloom_license_secret_arn:
        extra.append(("BloomLicenseSecretArn", bloom_license_secret_arn))
    if gds_license_secret_arn:
        extra.append(("GdsLicenseSecretArn", gds_license_secret_arn))
    if created_license_secret_arns:
        extra.append(("AutoCreatedLicenseSecretArns", ",".join(created_license_secret_arns)))
    extra.append(("StackID", stack_data["StackId"]))

    lines += [f"{k:<20} = {v}" for k, v in extra]
    output = "\n".join(lines) + "\n"
    print(output, end="")
    with open(outputs_file, "w") as f:
        f.write(output)
    cleanup_state["license_secret_arns"] = []

    print()
    print(f"Outputs saved to {outputs_file}")
    print()
    print(f"To test:      cd ../test_neo4j && uv run test-neo4j --edition ee --stack {stack_name}")
    print(f"To tear down: ./teardown.sh {stack_name}")


if __name__ == "__main__":
    main()
