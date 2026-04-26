"""AWS infrastructure validation: CloudFormation status, security groups, and CE checks."""

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
    """Run CE infrastructure validation tests."""
    check_stack_status(session, config, reporter)
    check_security_group_ports(session, config, reporter, resource_map)
    check_elastic_ip(session, config, reporter, resource_map)
    check_asg_config(session, config, reporter, resource_map)


# ---------------------------------------------------------------------------
# EE-specific checks
# ---------------------------------------------------------------------------

def check_nlb_scheme(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """EE public mode: verify the NLB is internet-facing."""
    with reporter.test("NLB scheme (internet-facing)") as ctx:
        nlb_arn = resource_map.get("Neo4jNetworkLoadBalancer")
        if not nlb_arn:
            ctx.fail("Neo4jNetworkLoadBalancer not found in stack resources")
            return
        try:
            elb = session.client("elbv2")
            resp = elb.describe_load_balancers(LoadBalancerArns=[nlb_arn])
            lbs = resp.get("LoadBalancers", [])
            if not lbs:
                ctx.fail(f"NLB {nlb_arn} not found")
                return
            scheme = lbs[0]["Scheme"]
            if scheme == "internet-facing":
                ctx.pass_(f"NLB {nlb_arn} is internet-facing")
            else:
                ctx.fail(f"NLB scheme is {scheme!r} (expected 'internet-facing')")
        except Exception as exc:
            ctx.fail(f"Failed to describe NLB {nlb_arn}: {exc}")


def check_ee_asg_configs(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """EE: verify each node ASG has min=max=desired=1 and HealthCheckType=ELB."""
    asg_client = session.client("autoscaling")
    for n in range(1, config.number_of_servers + 1):
        asg_logical_id = f"Neo4jNode{n}ASG"
        asg_name = resource_map.get(asg_logical_id)
        with reporter.test(f"ASG configuration (node {n})") as ctx:
            if not asg_name:
                ctx.fail(f"{asg_logical_id} not found in stack resources")
                continue
            try:
                groups = asg_client.describe_auto_scaling_groups(
                    AutoScalingGroupNames=[asg_name]
                )["AutoScalingGroups"]
                if not groups:
                    ctx.fail(f"ASG {asg_name} not found")
                    continue
                asg = groups[0]
                issues = []
                if asg["MinSize"] != 1:
                    issues.append(f"MinSize={asg['MinSize']}")
                if asg["MaxSize"] != 1:
                    issues.append(f"MaxSize={asg['MaxSize']}")
                if asg["DesiredCapacity"] != 1:
                    issues.append(f"DesiredCapacity={asg['DesiredCapacity']}")
                if asg["HealthCheckType"] != "ELB":
                    issues.append(f"HealthCheckType={asg['HealthCheckType']}")
                if not issues:
                    ctx.pass_(f"{asg_name}: min=1, max=1, desired=1, health_check=ELB")
                else:
                    ctx.fail(f"{asg_name} unexpected config: {', '.join(issues)}")
            except Exception as exc:
                ctx.fail(f"Failed to describe ASG {asg_name}: {exc}")


def run_ee_infra_checks(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
    *,
    run_security: bool = False,
) -> None:
    """Run EE infrastructure validation tests."""
    check_stack_status(session, config, reporter)
    check_nlb_scheme(session, config, reporter, resource_map)
    check_ee_asg_configs(session, config, reporter, resource_map)
    check_security_group_ports(session, config, reporter, resource_map)

    if run_security:
        run_network_security_checks(session, config, reporter, resource_map)


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
