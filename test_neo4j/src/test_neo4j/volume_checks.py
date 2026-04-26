"""Verify EBS volume layout via CloudFormation and EC2 APIs.

Checks that Neo4jDataVolume is in-use and attached to the running instance.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from test_neo4j.aws_helpers import get_all_ee_asg_instance_ids, get_asg_instance_id
from test_neo4j.config import StackConfig
from test_neo4j.reporting import TestReporter

if TYPE_CHECKING:
    import boto3

log = logging.getLogger(__name__)


def _describe_volume(session: boto3.Session, volume_id: str) -> dict:
    """Return the EC2 volume description for a given volume ID."""
    ec2 = session.client("ec2")
    resp = ec2.describe_volumes(VolumeIds=[volume_id])
    return resp["Volumes"][0]


def _check_volume(
    reporter: TestReporter,
    session: boto3.Session,
    instance_id: str,
    *,
    test_name: str,
    volume_id: str,
) -> dict | None:
    """Verify a volume exists, is in-use, and is attached to the expected instance.

    Returns the volume description on success, None on failure.
    """
    with reporter.test(test_name) as ctx:
        try:
            vol = _describe_volume(session, volume_id)
            state = vol["State"]
            size = vol["Size"]
            vol_type = vol["VolumeType"]
            encrypted = vol["Encrypted"]

            if state != "in-use":
                ctx.fail(
                    f"Volume {volume_id} exists but state is '{state}' (expected 'in-use')"
                )
                return None

            attachments = vol.get("Attachments", [])
            attached_to = [a["InstanceId"] for a in attachments if a["State"] == "attached"]

            if instance_id not in attached_to:
                ctx.fail(
                    f"Volume {volume_id} not attached to {instance_id}. "
                    f"Attached to: {attached_to or 'nothing'}"
                )
                return None

            ctx.pass_(
                f"{volume_id} attached to {instance_id} "
                f"({size} GB, {vol_type}, encrypted={encrypted})"
            )
            return vol

        except Exception as exc:
            ctx.fail(f"Failed to describe volume {volume_id}: {exc}")
            return None


def run_volume_checks(
    config: StackConfig,
    reporter: TestReporter,
    session: boto3.Session,
    resource_map: dict[str, str],
) -> None:
    """Verify EBS data volume is attached using CloudFormation resource IDs and EC2 APIs."""
    instance_id = get_asg_instance_id(session, config.stack_name, resource_map)
    log.info("  Checking volumes on instance: %s\n", instance_id)

    data_vol_id = resource_map.get("Neo4jDataVolume")

    if not data_vol_id:
        with reporter.test("EBS data volume") as ctx:
            ctx.fail("Neo4jDataVolume not found in CloudFormation stack resources")
        return

    _check_volume(
        reporter,
        session,
        instance_id,
        test_name="EBS data volume",
        volume_id=data_vol_id,
    )


def run_ee_volume_checks(
    config: StackConfig,
    reporter: TestReporter,
    session: boto3.Session,
    resource_map: dict[str, str],
) -> None:
    """Verify EBS data volumes for each EE node are attached."""
    node_pairs = get_all_ee_asg_instance_ids(
        session, config.stack_name, resource_map, config.number_of_servers
    )
    for n, (asg_logical_id, instance_id) in enumerate(node_pairs, start=1):
        log.info("  Node %d — instance: %s\n", n, instance_id)
        vol_logical_id = f"Neo4jNode{n}DataVolume"
        data_vol_id = resource_map.get(vol_logical_id)
        if not data_vol_id:
            with reporter.test(f"EBS data volume (node {n})") as ctx:
                ctx.fail(f"{vol_logical_id} not found in CloudFormation stack resources")
            continue
        _check_volume(
            reporter,
            session,
            instance_id,
            test_name=f"EBS data volume (node {n})",
            volume_id=data_vol_id,
        )
