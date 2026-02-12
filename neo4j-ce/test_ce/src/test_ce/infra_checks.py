"""AWS infrastructure validation: CloudFormation status, security groups, EIP, ASG."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from test_ce.config import StackConfig
from test_ce.reporting import TestReporter

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


def check_elastic_ip(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify the Elastic IP is allocated and associated with an instance."""
    with reporter.test("Elastic IP association") as ctx:
        eip_alloc = resource_map.get("Neo4jElasticIP")
        if not eip_alloc:
            ctx.fail("Neo4jElasticIP not found in stack resources")
            return

        try:
            ec2 = session.client("ec2")
            resp = ec2.describe_addresses(AllocationIds=[eip_alloc])
            addr = resp["Addresses"][0]
            association = addr.get("AssociationId")
            public_ip = addr.get("PublicIp", "unknown")

            if association:
                instance_id = addr.get("InstanceId", "unknown")
                ctx.pass_(
                    f"EIP {public_ip} ({eip_alloc}) associated with {instance_id}"
                )
            else:
                ctx.fail(
                    f"EIP {public_ip} ({eip_alloc}) is allocated but not associated "
                    "with any instance"
                )
        except Exception as exc:
            ctx.fail(f"Failed to describe Elastic IP {eip_alloc}: {exc}")


def check_asg_config(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify the ASG has min=max=desired=1 and health check type is EC2."""
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
                    f"ASG {asg_name}: min=1, max=1, desired=1, "
                    f"health_check=EC2"
                )
            else:
                ctx.fail(
                    f"ASG {asg_name} unexpected config: {', '.join(issues)}"
                )
        except Exception as exc:
            ctx.fail(f"Failed to describe ASG {asg_name}: {exc}")


def run_infra_checks(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Run all infrastructure validation tests."""
    check_stack_status(session, config, reporter)
    check_security_group_ports(session, config, reporter, resource_map)
    check_elastic_ip(session, config, reporter, resource_map)
    check_asg_config(session, config, reporter, resource_map)
