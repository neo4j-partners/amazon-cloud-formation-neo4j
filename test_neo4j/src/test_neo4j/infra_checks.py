"""AWS infrastructure validation: CloudFormation status, security groups, and edition-specific checks."""

from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING

from test_neo4j.config import StackConfig
from test_neo4j.reporting import TestReporter

if TYPE_CHECKING:
    import boto3

log = logging.getLogger(__name__)


def check_stack_status(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
) -> None:
    """Verify the CloudFormation stack is in a healthy terminal state."""
    with reporter.test("CloudFormation stack status") as ctx:
        try:
            cfn = session.client("cloudformation")
            resp = cfn.describe_stacks(StackName=config.stack_name)
            status = resp["Stacks"][0]["StackStatus"]
            if status in ("CREATE_COMPLETE", "UPDATE_COMPLETE"):
                ctx.pass_(f"Stack status is {status}")
            else:
                ctx.fail(
                    f"Stack status is {status} "
                    "(expected CREATE_COMPLETE or UPDATE_COMPLETE)"
                )
        except Exception as exc:
            ctx.fail(f"Failed to query stack status: {exc}")


def check_security_group_ports(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify the security group allows inbound on ports 7474 and 7687."""
    with reporter.test("Security group ports") as ctx:
        sg_id = resource_map.get("Neo4jExternalSecurityGroup")
        if not sg_id:
            ctx.fail("Neo4jExternalSecurityGroup not found in stack resources")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_security_groups(GroupIds=[sg_id])
            permissions = resp["SecurityGroups"][0]["IpPermissions"]
            open_ports = {p["FromPort"] for p in permissions if "FromPort" in p}

            missing = {7474, 7687} - open_ports
            if not missing:
                ctx.pass_(f"{sg_id} allows ports 7474 and 7687")
            else:
                ctx.fail(
                    f"{sg_id} missing expected ports: {missing} "
                    f"(open: {sorted(open_ports)})"
                )
        except Exception as exc:
            ctx.fail(f"Failed to describe security group {sg_id}: {exc}")


# ---------------------------------------------------------------------------
# CE-specific checks
# ---------------------------------------------------------------------------

def check_elastic_ip(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """CE only: verify the Elastic IP is allocated and associated with an instance."""
    with reporter.test("Elastic IP association") as ctx:
        eip_ip = resource_map.get("Neo4jElasticIP")
        if not eip_ip:
            ctx.fail("Neo4jElasticIP not found in stack resources")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_addresses(PublicIps=[eip_ip])
            addr = resp["Addresses"][0]
            association = addr.get("AssociationId")
            alloc_id = addr.get("AllocationId", "unknown")

            if association:
                instance_id = addr.get("InstanceId", "unknown")
                ctx.pass_(
                    f"EIP {eip_ip} ({alloc_id}) associated with {instance_id}"
                )
            else:
                ctx.fail(
                    f"EIP {eip_ip} ({alloc_id}) is allocated but not associated "
                    "with any instance"
                )
        except Exception as exc:
            ctx.fail(f"Failed to describe Elastic IP {eip_ip}: {exc}")


def check_asg_config(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """CE only: verify the ASG has min=max=desired=1 and health check type is EC2."""
    with reporter.test("ASG configuration") as ctx:
        asg_name = resource_map.get("Neo4jAutoScalingGroup")
        if not asg_name:
            ctx.fail("Neo4jAutoScalingGroup not found in stack resources")
            return

        try:
            asg_client = session.client("autoscaling")
            groups = asg_client.describe_auto_scaling_groups(
                AutoScalingGroupNames=[asg_name]
            )["AutoScalingGroups"]

            if not groups:
                ctx.fail(f"ASG {asg_name} not found")
                return

            asg = groups[0]
            min_size = asg["MinSize"]
            max_size = asg["MaxSize"]
            desired = asg["DesiredCapacity"]
            health_check = asg["HealthCheckType"]

            issues = []
            if min_size != 1:
                issues.append(f"MinSize={min_size}")
            if max_size != 1:
                issues.append(f"MaxSize={max_size}")
            if desired != 1:
                issues.append(f"DesiredCapacity={desired}")
            if health_check != "EC2":
                issues.append(f"HealthCheckType={health_check}")

            if not issues:
                ctx.pass_(
                    f"ASG {asg_name}: min=1, max=1, desired=1, health_check=EC2"
                )
            else:
                ctx.fail(
                    f"ASG {asg_name} unexpected config: {', '.join(issues)}"
                )
        except Exception as exc:
            ctx.fail(f"Failed to describe ASG {asg_name}: {exc}")


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def run_infra_checks(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Run infrastructure validation tests appropriate for the stack edition."""
    check_stack_status(session, config, reporter)
    check_security_group_ports(session, config, reporter, resource_map)

    if config.edition == "ce":
        check_elastic_ip(session, config, reporter, resource_map)
        check_asg_config(session, config, reporter, resource_map)
    # EE NLB and cluster checks are deferred


# ---------------------------------------------------------------------------
# Network and instance security checks
# ---------------------------------------------------------------------------

def check_external_sg_cidr(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify external SG ingress CIDRs on ports 7474/7687 match the AllowedCIDR stack parameter."""
    with reporter.test("External SG ingress CIDR") as ctx:
        try:
            cfn = session.client("cloudformation")
            cfn_resp = cfn.describe_stacks(StackName=config.stack_name)
            params = {
                p["ParameterKey"]: p["ParameterValue"]
                for p in cfn_resp["Stacks"][0].get("Parameters", [])
            }
            expected_cidr = params.get("AllowedCIDR")
            if expected_cidr is None:
                ctx.fail(
                    "AllowedCIDR parameter not found in stack — "
                    "stack may have been deployed before this parameter was added"
                )
                return

            sg_id = resource_map.get("Neo4jExternalSecurityGroup")
            if not sg_id:
                ctx.fail("Neo4jExternalSecurityGroup not found in stack resources")
                return

            ec2 = session.client("ec2")
            ec2_resp = ec2.describe_security_groups(GroupIds=[sg_id])
            permissions = ec2_resp["SecurityGroups"][0]["IpPermissions"]

            port_cidrs: dict[int, list[str]] = {}
            for perm in permissions:
                port = perm.get("FromPort")
                if port in (7474, 7687):
                    port_cidrs[port] = [r["CidrIp"] for r in perm.get("IpRanges", [])]

            issues = []
            for port in (7474, 7687):
                cidrs = port_cidrs.get(port, [])
                if not cidrs:
                    issues.append(f"port {port}: no CIDR found")
                elif expected_cidr not in cidrs:
                    issues.append(f"port {port}: {cidrs} (expected {expected_cidr})")

            if not issues:
                ctx.pass_(f"{sg_id} ports 7474/7687 restricted to {expected_cidr}")
            else:
                ctx.fail(f"CIDR mismatch on {sg_id}: {'; '.join(issues)}")
        except Exception as exc:
            ctx.fail(f"Failed to check external SG CIDR: {exc}")


def check_port_5005_absent(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify port 5005 (JDWP remote debug) is not open in the internal security group."""
    with reporter.test("Port 5005 absent from internal security group") as ctx:
        sg_id = resource_map.get("Neo4jInternalSecurityGroup")
        if not sg_id:
            ctx.fail("Neo4jInternalSecurityGroup not found in stack resources")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_security_groups(GroupIds=[sg_id])
            permissions = resp["SecurityGroups"][0]["IpPermissions"]
            open_ports = {p["FromPort"] for p in permissions if "FromPort" in p}

            if 5005 in open_ports:
                ctx.fail(f"{sg_id} has port 5005 open (JDWP remote debug port must be closed)")
            else:
                ctx.pass_(f"{sg_id} does not allow port 5005")
        except Exception as exc:
            ctx.fail(f"Failed to check internal SG ports: {exc}")


def check_internal_sg_self_reference(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify internal SG ingress rules source from the internal SG itself, not the external SG."""
    with reporter.test("Internal SG ingress sources itself") as ctx:
        int_sg_id = resource_map.get("Neo4jInternalSecurityGroup")
        if not int_sg_id:
            ctx.fail("Neo4jInternalSecurityGroup not found in stack resources")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_security_groups(GroupIds=[int_sg_id])
            permissions = resp["SecurityGroups"][0]["IpPermissions"]

            wrong_source = []
            for perm in permissions:
                port = perm.get("FromPort")
                for pair in perm.get("UserIdGroupPairs", []):
                    source = pair.get("GroupId")
                    if source != int_sg_id:
                        wrong_source.append(f"port {port}: source={source}")

            if wrong_source:
                ctx.fail(
                    f"{int_sg_id} has rules sourcing from an external group: "
                    f"{'; '.join(wrong_source)}"
                )
            else:
                ctx.pass_(f"{int_sg_id} all cluster port ingress rules source from itself")
        except Exception as exc:
            ctx.fail(f"Failed to check internal SG source: {exc}")


def check_imdsv2_enforced(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify the launch template enforces IMDSv2 (HttpTokens: required)."""
    with reporter.test("IMDSv2 enforced on launch template") as ctx:
        lt_id = resource_map.get("Neo4jLaunchTemplate")
        if not lt_id:
            ctx.fail("Neo4jLaunchTemplate not found in stack resources")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_launch_template_versions(
                LaunchTemplateId=lt_id,
                Versions=["$Latest"],
            )
            versions = resp.get("LaunchTemplateVersions", [])
            if not versions:
                ctx.fail(f"No versions found for launch template {lt_id}")
                return

            metadata_opts = versions[0].get("LaunchTemplateData", {}).get("MetadataOptions", {})
            http_tokens = metadata_opts.get("HttpTokens", "")

            if http_tokens == "required":
                ctx.pass_(f"{lt_id} MetadataOptions.HttpTokens = required")
            else:
                ctx.fail(
                    f"{lt_id} MetadataOptions.HttpTokens = {http_tokens!r} (expected 'required')"
                )
        except Exception as exc:
            ctx.fail(f"Failed to check launch template metadata options: {exc}")


def check_jdwp_absent(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify JDWP is not configured in neo4j.conf on a running instance via SSM Run Command."""
    with reporter.test("JDWP absent from neo4j.conf") as ctx:
        from test_neo4j.aws_helpers import get_asg_instance_id  # noqa: PLC0415

        try:
            instance_id = get_asg_instance_id(session, config.stack_name, resource_map)
        except RuntimeError as exc:
            ctx.fail(f"Could not get an InService instance: {exc}")
            return

        ssm = session.client("ssm")

        try:
            resp = ssm.send_command(
                InstanceIds=[instance_id],
                DocumentName="AWS-RunShellScript",
                Parameters={
                    "commands": [
                        "grep -iq jdwp /etc/neo4j/neo4j.conf "
                        "&& echo JDWP_FOUND "
                        "|| echo JDWP_NOT_FOUND"
                    ]
                },
            )
            command_id = resp["Command"]["CommandId"]
        except Exception as exc:
            ctx.fail(f"Failed to send SSM command to {instance_id}: {exc}")
            return

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            time.sleep(2)
            try:
                inv = ssm.get_command_invocation(
                    CommandId=command_id,
                    InstanceId=instance_id,
                )
                status = inv["Status"]
                if status in ("Success", "Failed", "Cancelled", "TimedOut"):
                    output = inv.get("StandardOutputContent", "").strip()
                    if "JDWP_NOT_FOUND" in output:
                        ctx.pass_(f"{instance_id}: JDWP not present in neo4j.conf")
                    elif "JDWP_FOUND" in output:
                        ctx.fail(
                            f"{instance_id}: JDWP line found in neo4j.conf — "
                            "debug port configuration was not removed at boot"
                        )
                    else:
                        ctx.fail(
                            f"{instance_id}: unexpected SSM output (status={status}): "
                            f"{output!r}"
                        )
                    return
            except Exception as exc:
                response = getattr(exc, "response", None)
                error_code = (
                    response.get("Error", {}).get("Code", "")
                    if isinstance(response, dict)
                    else ""
                )
                if error_code == "InvocationDoesNotExist":
                    pass  # command not yet registered on the instance — keep polling
                else:
                    ctx.fail(f"SSM polling error: {exc}")
                    return

        ctx.fail(
            f"SSM command did not complete within 30s on {instance_id} — "
            "check that SSM agent is running and the instance profile has ssm:SendCommand"
        )


# ---------------------------------------------------------------------------
# Private-mode infrastructure checks
# ---------------------------------------------------------------------------

def check_nlb_scheme(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify NLB scheme: internal for Private mode, internet-facing for Public mode."""
    with reporter.test("NLB scheme") as ctx:
        nlb_arn = resource_map.get("Neo4jNetworkLoadBalancer")
        if not nlb_arn:
            ctx.fail("Neo4jNetworkLoadBalancer not found in stack resources")
            return
        try:
            elbv2 = session.client("elbv2")
            resp = elbv2.describe_load_balancers(LoadBalancerArns=[nlb_arn])
            scheme = resp["LoadBalancers"][0]["Scheme"]
            expected = "internal" if config.deployment_mode == "Private" else "internet-facing"
            if scheme == expected:
                ctx.pass_(f"NLB scheme is {scheme!r}")
            else:
                ctx.fail(f"NLB scheme is {scheme!r} (expected {expected!r})")
        except Exception as exc:
            ctx.fail(f"Failed to describe NLB {nlb_arn}: {exc}")


def check_instances_no_public_ip(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify all InService instances have no public IP (Private mode only)."""
    with reporter.test("Instances have no public IP") as ctx:
        from test_neo4j.aws_helpers import get_asg_instance_ids  # noqa: PLC0415

        try:
            instance_ids = get_asg_instance_ids(session, config.stack_name, resource_map)
        except RuntimeError as exc:
            ctx.fail(f"Could not list InService instances: {exc}")
            return

        if not instance_ids:
            ctx.fail("No InService instances found in ASG")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_instances(InstanceIds=instance_ids)
            with_public_ip = []
            for reservation in resp["Reservations"]:
                for inst in reservation["Instances"]:
                    iid = inst["InstanceId"]
                    public_ip = inst.get("PublicIpAddress")
                    if public_ip:
                        with_public_ip.append(f"{iid}={public_ip}")

            if with_public_ip:
                ctx.fail(
                    f"Instances with public IPs (expected none in Private mode): "
                    f"{', '.join(with_public_ip)}"
                )
            else:
                ctx.pass_(f"All {len(instance_ids)} instances have no public IP")
        except Exception as exc:
            ctx.fail(f"Failed to describe instances: {exc}")


def check_instances_in_private_subnets(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify all InService instances are in the stack's private subnets."""
    with reporter.test("Instances in private subnets") as ctx:
        from test_neo4j.aws_helpers import get_asg_instance_ids  # noqa: PLC0415

        private_subnet_ids = {
            v for k, v in resource_map.items()
            if k.startswith("Neo4jPrivateSubnet") and v
        }
        if not private_subnet_ids:
            ctx.fail("No Neo4jPrivateSubnet* resources found in stack")
            return

        try:
            instance_ids = get_asg_instance_ids(session, config.stack_name, resource_map)
        except RuntimeError as exc:
            ctx.fail(f"Could not list InService instances: {exc}")
            return

        if not instance_ids:
            ctx.fail("No InService instances found in ASG")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_instances(InstanceIds=instance_ids)
            wrong_subnet = []
            for reservation in resp["Reservations"]:
                for inst in reservation["Instances"]:
                    subnet = inst.get("SubnetId", "")
                    if subnet not in private_subnet_ids:
                        wrong_subnet.append(f"{inst['InstanceId']}={subnet}")

            if wrong_subnet:
                ctx.fail(
                    f"Instances not in private subnets {private_subnet_ids}: "
                    f"{', '.join(wrong_subnet)}"
                )
            else:
                ctx.pass_(
                    f"All {len(instance_ids)} instances are in private subnets "
                    f"({', '.join(sorted(private_subnet_ids))})"
                )
        except Exception as exc:
            ctx.fail(f"Failed to describe instances: {exc}")


def check_vpc_endpoints_available(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify all required VPC endpoints exist and are available."""
    with reporter.test("VPC endpoints available") as ctx:
        vpc_id = resource_map.get("Neo4jVPC")
        if not vpc_id:
            ctx.fail("Neo4jVPC not found in stack resources")
            return

        region = config.region
        required_services = {
            f"com.amazonaws.{region}.ssm",
            f"com.amazonaws.{region}.ssmmessages",
            f"com.amazonaws.{region}.ec2messages",
            f"com.amazonaws.{region}.logs",
            f"com.amazonaws.{region}.s3",
        }

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_vpc_endpoints(
                Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
            )
            endpoints = resp["VpcEndpoints"]

            available = {
                ep["ServiceName"]
                for ep in endpoints
                if ep.get("State") == "available"
            }
            not_available = {
                ep["ServiceName"]: ep.get("State")
                for ep in endpoints
                if ep["ServiceName"] in required_services and ep.get("State") != "available"
            }
            missing = required_services - {ep["ServiceName"] for ep in endpoints}

            issues = []
            if missing:
                issues.append(f"missing: {', '.join(sorted(missing))}")
            if not_available:
                issues.append(
                    f"not available: "
                    f"{', '.join(f'{s}={st}' for s, st in not_available.items())}"
                )

            if not issues:
                ctx.pass_(f"All 5 required VPC endpoints are available in {vpc_id}")
            else:
                ctx.fail(f"VPC endpoint check failed: {'; '.join(issues)}")
        except Exception as exc:
            ctx.fail(f"Failed to describe VPC endpoints for {vpc_id}: {exc}")


def check_vpc_endpoint_sg_uses_sg_source(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify VpcEndpointSecurityGroup port-443 ingress uses SG sources, not CIDR.

    Expected sources: Neo4jExternalSecurityGroup (cluster members) and
    Neo4jBastionSecurityGroup (operator bastion). Fails if any CIDR is
    present or if either expected SG is missing.
    """
    with reporter.test("VPC endpoint SG uses SG source (not CIDR)") as ctx:
        ep_sg_id = resource_map.get("VpcEndpointSecurityGroup")
        ext_sg_id = resource_map.get("Neo4jExternalSecurityGroup")
        bastion_sg_id = resource_map.get("Neo4jBastionSecurityGroup")
        if not ep_sg_id:
            ctx.fail("VpcEndpointSecurityGroup not found in stack resources")
            return
        if not ext_sg_id:
            ctx.fail("Neo4jExternalSecurityGroup not found in stack resources")
            return
        if not bastion_sg_id:
            ctx.fail("Neo4jBastionSecurityGroup not found in stack resources")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_security_groups(GroupIds=[ep_sg_id])
            permissions = resp["SecurityGroups"][0]["IpPermissions"]

            port_443_rules = [
                p for p in permissions
                if p.get("FromPort") == 443 and p.get("ToPort") == 443
            ]
            if not port_443_rules:
                ctx.fail(f"{ep_sg_id} has no port-443 ingress rule")
                return

            all_cidrs: list[str] = []
            all_sg_sources: set[str] = set()
            for rule in port_443_rules:
                all_cidrs.extend(r["CidrIp"] for r in rule.get("IpRanges", []))
                all_sg_sources.update(
                    p["GroupId"] for p in rule.get("UserIdGroupPairs", [])
                )

            issues = []
            if all_cidrs:
                issues.append(f"CIDR ranges present: {all_cidrs}")
            if ext_sg_id not in all_sg_sources:
                issues.append(
                    f"Neo4jExternalSecurityGroup ({ext_sg_id}) not in SG sources: "
                    f"{sorted(all_sg_sources)}"
                )
            if bastion_sg_id not in all_sg_sources:
                issues.append(
                    f"Neo4jBastionSecurityGroup ({bastion_sg_id}) not in SG sources: "
                    f"{sorted(all_sg_sources)}"
                )

            if not issues:
                ctx.pass_(
                    f"{ep_sg_id} port-443 ingress locked to SG sources "
                    f"(external={ext_sg_id}, bastion={bastion_sg_id})"
                )
            else:
                ctx.fail(f"{ep_sg_id} port-443 rule issues: {'; '.join(issues)}")
        except Exception as exc:
            ctx.fail(f"Failed to describe security group {ep_sg_id}: {exc}")


def check_nat_gateways_available(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify NAT Gateway count matches deployment: 1 for single-instance, 3 for cluster."""
    with reporter.test("NAT Gateways available") as ctx:
        vpc_id = resource_map.get("Neo4jVPC")
        if not vpc_id:
            ctx.fail("Neo4jVPC not found in stack resources")
            return

        expected = 3 if resource_map.get("Neo4jNatGateway2") else 1

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_nat_gateways(
                Filter=[
                    {"Name": "vpc-id", "Values": [vpc_id]},
                    {"Name": "state", "Values": ["available"]},
                ]
            )
            count = len(resp["NatGateways"])
            if count == expected:
                ctx.pass_(f"{count} NAT Gateway(s) available in {vpc_id}")
            else:
                ctx.fail(
                    f"Expected {expected} available NAT Gateway(s) in {vpc_id}, found {count}"
                )
        except Exception as exc:
            ctx.fail(f"Failed to describe NAT Gateways for {vpc_id}: {exc}")


def check_operator_bastion(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify the operator bastion exists, is SSM-registered, and is not an NLB target.

    The bastion's whole purpose is to carry operator tunnels from an IP that is
    not in any NLB target group, so that NLB flow-hash cannot route a tunnelled
    flow back to its source. This check guards against template edits that would
    silently reintroduce the hairpin failure mode (removing the bastion entirely
    or, worse, accidentally registering it as a target).
    """
    with reporter.test("Operator bastion exists and is non-NLB-target") as ctx:
        bastion_id = resource_map.get("Neo4jOperatorBastion")
        http_tg_arn = resource_map.get("Neo4jHTTPTargetGroup")
        bolt_tg_arn = resource_map.get("Neo4jBoltTargetGroup")

        if not bastion_id:
            ctx.fail("Neo4jOperatorBastion not found in stack resources")
            return
        if not http_tg_arn or not bolt_tg_arn:
            ctx.fail("NLB target groups not found in stack resources")
            return

        try:
            ssm = session.client("ssm")
            info = ssm.describe_instance_information(
                Filters=[{"Key": "InstanceIds", "Values": [bastion_id]}]
            )["InstanceInformationList"]
            if not info or info[0].get("PingStatus") != "Online":
                ping = info[0].get("PingStatus") if info else "not-registered"
                ctx.fail(
                    f"Bastion {bastion_id} not Online in SSM (PingStatus={ping})"
                )
                return

            elbv2 = session.client("elbv2")
            for tg_arn, label in ((http_tg_arn, "HTTP"), (bolt_tg_arn, "Bolt")):
                health = elbv2.describe_target_health(TargetGroupArn=tg_arn)[
                    "TargetHealthDescriptions"
                ]
                target_ids = {d["Target"]["Id"] for d in health}
                if bastion_id in target_ids:
                    ctx.fail(
                        f"Bastion {bastion_id} is registered in the {label} "
                        f"target group ({tg_arn}) — this reintroduces NLB hairpin"
                    )
                    return

            ctx.pass_(
                f"Bastion {bastion_id} is Online in SSM and not registered "
                "in either NLB target group"
            )
        except Exception as exc:
            ctx.fail(f"Failed to check bastion {bastion_id}: {exc}")


def check_target_group_client_ip_disabled(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify preserve_client_ip.enabled=false on both NLB target groups.

    Required second layer (together with the non-target bastion) to prevent
    NLB NAT-loopback hairpin failures. See README "Why the operator bastion
    exists — NLB hairpin".
    """
    with reporter.test("NLB target groups disable client IP preservation") as ctx:
        http_tg_arn = resource_map.get("Neo4jHTTPTargetGroup")
        bolt_tg_arn = resource_map.get("Neo4jBoltTargetGroup")
        if not http_tg_arn or not bolt_tg_arn:
            ctx.fail("NLB target groups not found in stack resources")
            return

        try:
            elbv2 = session.client("elbv2")
            issues = []
            for tg_arn, label in ((http_tg_arn, "HTTP"), (bolt_tg_arn, "Bolt")):
                attrs = {
                    a["Key"]: a["Value"]
                    for a in elbv2.describe_target_group_attributes(
                        TargetGroupArn=tg_arn
                    )["Attributes"]
                }
                value = attrs.get("preserve_client_ip.enabled")
                if value != "false":
                    issues.append(
                        f"{label} target group preserve_client_ip.enabled="
                        f"{value!r} (expected 'false')"
                    )

            if not issues:
                ctx.pass_(
                    "Both target groups have preserve_client_ip.enabled=false"
                )
            else:
                ctx.fail("; ".join(issues))
        except Exception as exc:
            ctx.fail(f"Failed to check target group attributes: {exc}")


def check_vpc_dns_support(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify VPC has enableDnsSupport and enableDnsHostnames both enabled."""
    with reporter.test("VPC DNS support and hostnames enabled") as ctx:
        vpc_id = resource_map.get("Neo4jVPC")
        if not vpc_id:
            ctx.fail("Neo4jVPC not found in stack resources")
            return

        try:
            ec2 = session.client("ec2")
            support = ec2.describe_vpc_attribute(
                VpcId=vpc_id, Attribute="enableDnsSupport"
            )["EnableDnsSupport"]["Value"]
            hostnames = ec2.describe_vpc_attribute(
                VpcId=vpc_id, Attribute="enableDnsHostnames"
            )["EnableDnsHostnames"]["Value"]

            issues = []
            if not support:
                issues.append("enableDnsSupport=false")
            if not hostnames:
                issues.append("enableDnsHostnames=false")

            if not issues:
                ctx.pass_(f"{vpc_id} has enableDnsSupport=true, enableDnsHostnames=true")
            else:
                ctx.fail(f"{vpc_id} DNS config issues: {', '.join(issues)}")
        except Exception as exc:
            ctx.fail(f"Failed to describe VPC attributes for {vpc_id}: {exc}")


def run_private_mode_checks(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Run Private-mode infrastructure checks (EE only, skipped for Public deployments)."""
    if config.deployment_mode != "Private":
        log.info(
            "DeploymentMode=%s — skipping Private-mode infrastructure checks.",
            config.deployment_mode,
        )
        return

    check_nlb_scheme(session, config, reporter, resource_map)
    check_instances_no_public_ip(session, config, reporter, resource_map)
    check_instances_in_private_subnets(session, config, reporter, resource_map)
    check_vpc_endpoints_available(session, config, reporter, resource_map)
    check_vpc_endpoint_sg_uses_sg_source(session, config, reporter, resource_map)
    check_nat_gateways_available(session, config, reporter, resource_map)
    check_vpc_dns_support(session, config, reporter, resource_map)
    check_operator_bastion(session, config, reporter, resource_map)
    check_target_group_client_ip_disabled(session, config, reporter, resource_map)


def run_network_security_checks(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify network hardening and instance security configuration.

    Checks that external SG ingress CIDRs match the deployed AllowedCIDR parameter,
    that the JDWP remote debug port is closed, that internal cluster ports are
    reachable only from within the cluster, that IMDSv2 is enforced on the launch
    template, and that JDWP is not configured in neo4j.conf on running instances.
    """
    check_external_sg_cidr(session, config, reporter, resource_map)
    check_port_5005_absent(session, config, reporter, resource_map)
    check_internal_sg_self_reference(session, config, reporter, resource_map)
    check_imdsv2_enforced(session, config, reporter, resource_map)
    check_jdwp_absent(session, config, reporter, resource_map)
