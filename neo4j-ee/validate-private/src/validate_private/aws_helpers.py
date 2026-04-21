"""Shared AWS helpers for CloudFormation and Auto Scaling lookups."""

from __future__ import annotations


def stack_resources(cfn, stack_name: str) -> dict[str, str]:
    paginator = cfn.get_paginator("list_stack_resources")
    result = {}
    for page in paginator.paginate(StackName=stack_name):
        for r in page["StackResourceSummaries"]:
            result[r["LogicalResourceId"]] = r["PhysicalResourceId"]
    return result


def asg_instances(asg, asg_name: str) -> list[str]:
    """Return InService instance IDs in an ASG."""
    groups = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])["AutoScalingGroups"]
    if not groups:
        return []
    return [i["InstanceId"] for i in groups[0]["Instances"] if i["LifecycleState"] == "InService"]
