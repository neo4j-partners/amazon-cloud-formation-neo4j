"""AWS operations via boto3: ASG lookup, instance termination, NLB health polling."""

from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import boto3

log = logging.getLogger(__name__)


def get_stack_resources(session: boto3.Session, stack_name: str) -> dict[str, str]:
    """Return a mapping of LogicalResourceId -> PhysicalResourceId for the stack."""
    cfn = session.client("cloudformation")
    resources = cfn.describe_stack_resources(StackName=stack_name)["StackResources"]
    return {r["LogicalResourceId"]: r["PhysicalResourceId"] for r in resources}


def get_asg_instance_id(
    session: boto3.Session,
    stack_name: str,
    resource_map: dict[str, str] | None = None,
) -> str:
    """Return the EC2 instance ID of the single InService instance in the stack's ASG."""
    if resource_map is None:
        resource_map = get_stack_resources(session, stack_name)

    asg_name = resource_map.get("Neo4jAutoScalingGroup")
    if not asg_name:
        raise RuntimeError(f"Neo4jAutoScalingGroup not found in stack {stack_name}")

    asg_client = session.client("autoscaling")
    groups = asg_client.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )["AutoScalingGroups"]

    if not groups:
        raise RuntimeError(f"ASG {asg_name} not found")

    instances = groups[0]["Instances"]
    for instance in instances:
        if instance["LifecycleState"] == "InService":
            return instance["InstanceId"]

    states = [f"{i['InstanceId']}={i['LifecycleState']}" for i in instances]
    raise RuntimeError(
        f"No InService instance in ASG {asg_name}. "
        f"Current states: {', '.join(states) or 'none'}"
    )


def get_http_target_group_arn(
    stack_name: str,
    resource_map: dict[str, str],
) -> str:
    """Return the ARN of the HTTP target group from the stack resources."""
    arn = resource_map.get("Neo4jHTTPTargetGroup")
    if not arn:
        raise RuntimeError(f"Neo4jHTTPTargetGroup not found in stack {stack_name}")
    return arn


def terminate_instance(session: boto3.Session, instance_id: str) -> None:
    """Terminate an EC2 instance. The ASG will launch a replacement."""
    ec2 = session.client("ec2")
    ec2.terminate_instances(InstanceIds=[instance_id])
    log.info("  Terminated instance %s", instance_id)


def wait_for_healthy_target(
    session: boto3.Session,
    target_group_arn: str,
    *,
    exclude_instance: str | None = None,
    timeout: int = 600,
    interval: int = 15,
) -> str:
    """Poll the NLB target group until a target is healthy. Return its instance ID.

    If *exclude_instance* is given, ignore that ID (the just-terminated instance
    may linger as "healthy" in the target group briefly after termination).
    """
    elbv2 = session.client("elbv2")
    deadline = time.monotonic() + timeout

    while True:
        resp = elbv2.describe_target_health(TargetGroupArn=target_group_arn)
        for desc in resp["TargetHealthDescriptions"]:
            instance_id = desc["Target"]["Id"]
            if desc["TargetHealth"]["State"] == "healthy" and instance_id != exclude_instance:
                elapsed = timeout - (deadline - time.monotonic())
                log.info("  Target %s is healthy (%.0fs elapsed)", instance_id, elapsed)
                return instance_id

        elapsed = timeout - (deadline - time.monotonic())

        # Show current state for visibility
        states = [
            f"{d['Target']['Id']}={d['TargetHealth']['State']}"
            for d in resp["TargetHealthDescriptions"]
        ]
        if states:
            log.info("  Targets: %s (%.0fs elapsed)", ", ".join(states), elapsed)
        else:
            log.info("  No targets registered yet (%.0fs elapsed)", elapsed)

        if time.monotonic() >= deadline:
            break

        time.sleep(interval)

    raise TimeoutError(
        f"No healthy target in {target_group_arn} after {timeout}s. "
        "Check ASG activity and instance logs."
    )
