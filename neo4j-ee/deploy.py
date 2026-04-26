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
INSTANCE_TYPES = {"t3": "t3.medium", "r8i": "r8i.xlarge"}
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
        "instance_family", nargs="?", default="t3",
        choices=list(INSTANCE_TYPES), metavar="INSTANCE_FAMILY",
        help="Instance family: t3 (default) or r8i",
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


def main():
    os.environ.setdefault("AWS_PROFILE", "default")
    args = parse_args()

    if args.mode == "ExistingVpc":
        if not args.vpc_id or not args.subnet_1:
            sys.exit("ERROR: --mode ExistingVpc requires --vpc-id and --subnet-1 (--subnet-2 and --subnet-3 required for 3-node).")
        if args.number_of_servers == 3 and not (args.subnet_2 and args.subnet_3):
            sys.exit("ERROR: --mode ExistingVpc with 3 servers requires --subnet-2 and --subnet-3.")
        if args.create_vpc_endpoints == "false" and not args.existing_endpoint_sg_id:
            sys.exit("ERROR: --existing-endpoint-sg-id is required when --create-vpc-endpoints false")

    instance_type = INSTANCE_TYPES[args.instance_family]

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

    cleanup_state = {
        "cfn_bucket": None,
        "copied_ami_id": None,
        "cleanup_ami": False,
        "tls_secret_arn": None,
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
        if cleanup_state["cleanup_ami"] and cleanup_state["copied_ami_id"]:
            ami = cleanup_state["copied_ami_id"]
            print(f"\nCleaning up copied AMI {ami} in {region}...")
            try:
                ec2 = boto3.client("ec2", region_name=region)
                ec2.deregister_image(ImageId=ami)
                snaps = ec2.describe_snapshots(
                    Filters=[{"Name": "description", "Values": [f"*{ami}*"]}]
                )["Snapshots"]
                for snap in snaps:
                    ec2.delete_snapshot(SnapshotId=snap["SnapshotId"])
            except Exception as e:
                print(f"  Warning: could not fully clean up AMI {ami}: {e}")
        if cleanup_state["tls_secret_arn"]:
            arn = cleanup_state["tls_secret_arn"]
            print(f"\nCleaning up TLS secret {arn}...")
            try:
                boto3.client("secretsmanager", region_name=region).delete_secret(
                    SecretId=arn, ForceDeleteWithoutRecovery=True
                )
            except Exception as e:
                print(f"  Warning: could not delete TLS secret: {e}")

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
                f"ERROR: {ami_id_file} not found. Run marketplace/build.sh first,\n"
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
                cleanup_state["cleanup_ami"] = False
            elif pending:
                copied_ami_id = pending[0]["ImageId"]
                print(f"Found in-progress AMI copy {copied_ami_id} in {region} — waiting for it to become available...")
                ec2.get_waiter("image_available").wait(
                    ImageIds=[copied_ami_id],
                    WaiterConfig={"Delay": 30, "MaxAttempts": 60},
                )
                print(f"AMI available in {region}.")
                cleanup_state["copied_ami_id"] = copied_ami_id
                cleanup_state["cleanup_ami"] = False
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
                cleanup_state["cleanup_ami"] = True
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
    print(f"  Instance:       {instance_type} (family: {args.instance_family})")
    print(f"  Servers:        {args.number_of_servers}")
    print(f"  Mode:           {args.mode}")
    print(f"  AllowedCIDR:    {allowed_cidr}")
    print(f"  TLS:            {args.tls}")
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

    cfn_params = [
        {"ParameterKey": "Password", "ParameterValue": password},
        {"ParameterKey": "NumberOfServers", "ParameterValue": str(args.number_of_servers)},
        {"ParameterKey": "InstanceType", "ParameterValue": instance_type},
        {"ParameterKey": "AllowedCIDR", "ParameterValue": allowed_cidr},
    ]
    if ssm_param_path:
        cfn_params.append({"ParameterKey": "ImageId", "ParameterValue": ssm_param_path})
    if args.alert_email:
        cfn_params.append({"ParameterKey": "AlertEmail", "ParameterValue": args.alert_email})
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

    cleanup_state["cleanup_ami"] = False

    bolt_tls_secret_arn = ""
    if args.tls:
        print()
        print("--- TLS Phase: generating self-signed cert and updating stack ---")

        nlb_dns = boto3.client("ssm", region_name=region).get_parameter(
            Name=f"/neo4j-ee/{stack_name}/nlb-dns"
        )["Parameter"]["Value"]
        print(f"NLB DNS: {nlb_dns}")

        cert_pem, key_pem = generate_tls_cert(nlb_dns)
        print(f"Self-signed cert generated (SAN: DNS:{nlb_dns})")

        bolt_tls_secret_arn = boto3.client("secretsmanager", region_name=region).create_secret(
            Name=f"neo4j-bolt-tls-{stack_name}",
            SecretString=json.dumps({"certificate": cert_pem, "private_key": key_pem}),
        )["ARN"]
        cleanup_state["tls_secret_arn"] = bolt_tls_secret_arn
        print(f"Secrets Manager secret created: {bolt_tls_secret_arn}")

        lambda_dir = os.path.join(SCRIPT_DIR, "sample-private-app", "lambda")
        ca_path = os.path.join(lambda_dir, "neo4j-ca.crt")
        with open(ca_path, "w") as f:
            f.write(cert_pem)
        print(f"CA bundle staged at {ca_path}")

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
        print("TLS enabled on Bolt. To activate on the Lambda:")
        print(f"  cd {SCRIPT_DIR}/sample-private-app && cdk deploy")
        print("(neo4j-ca.crt is already staged in the lambda/ directory)")

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
    ]
    if args.alert_email:
        extra.append(("AlertEmail", args.alert_email))
    if args.mode == "ExistingVpc":
        extra.append(("CreateVpcEndpoints", args.create_vpc_endpoints))
        if args.existing_endpoint_sg_id:
            extra.append(("ExistingEndpointSgId", args.existing_endpoint_sg_id))
    if ssm_param_path:
        extra.extend([("SSMParamPath", ssm_param_path), ("AmiId", ami_id)])
    if cleanup_state["copied_ami_id"] and cleanup_state["cleanup_ami"]:
        extra.extend([("CopiedAmiId", cleanup_state["copied_ami_id"]), ("SourceRegion", SOURCE_REGION)])
    if bolt_tls_secret_arn:
        extra.append(("BoltTlsSecretArn", bolt_tls_secret_arn))
    extra.append(("StackID", stack_data["StackId"]))

    lines += [f"{k:<20} = {v}" for k, v in extra]
    output = "\n".join(lines) + "\n"
    print(output, end="")
    with open(outputs_file, "w") as f:
        f.write(output)

    print()
    print(f"Outputs saved to {outputs_file}")
    print()
    print(f"To test:      cd test_neo4j && uv run test-neo4j --edition ee --stack {stack_name}")
    print(f"To tear down: ./teardown.sh {stack_name}")


if __name__ == "__main__":
    main()
