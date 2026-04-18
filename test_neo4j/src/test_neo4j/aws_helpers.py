"""AWS operations via boto3: ASG lookup, instance termination, replacement polling."""

from __future__ import annotations

import contextlib
import logging
import os
import shutil
import signal
import socket
import subprocess
import threading
import time
from collections.abc import Iterator
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


def get_asg_instance_ids(
    session: boto3.Session,
    stack_name: str,
    resource_map: dict[str, str] | None = None,
) -> list[str]:
    """Return EC2 instance IDs for all InService instances in the stack's ASG."""
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

    return [
        i["InstanceId"]
        for i in groups[0]["Instances"]
        if i["LifecycleState"] == "InService"
    ]


def wait_for_cluster_recovery(
    session: boto3.Session,
    stack_name: str,
    resource_map: dict[str, str],
    *,
    terminated_instance: str,
    expected_count: int,
    timeout: int = 600,
    interval: int = 15,
) -> list[str]:
    """Poll the ASG until expected_count InService instances exist, excluding terminated_instance.

    Returns the list of recovered InService instance IDs.
    Unlike wait_for_replacement_instance (CE), this is safe for multi-node clusters where
    other instances remain InService during the replacement.
    """
    asg_name = resource_map.get("Neo4jAutoScalingGroup")
    if not asg_name:
        raise RuntimeError(f"Neo4jAutoScalingGroup not found in stack {stack_name}")

    asg_client = session.client("autoscaling")
    deadline = time.monotonic() + timeout

    while True:
        try:
            groups = asg_client.describe_auto_scaling_groups(
                AutoScalingGroupNames=[asg_name]
            )["AutoScalingGroups"]

            if groups:
                in_service = [
                    i["InstanceId"]
                    for i in groups[0]["Instances"]
                    if i["LifecycleState"] == "InService"
                    and i["InstanceId"] != terminated_instance
                ]
                if len(in_service) >= expected_count:
                    elapsed = timeout - (deadline - time.monotonic())
                    log.info(
                        "  Cluster recovered: %d InService instances (%.0fs elapsed)",
                        len(in_service),
                        elapsed,
                    )
                    return in_service

                elapsed = timeout - (deadline - time.monotonic())
                states = [
                    f"{i['InstanceId']}={i['LifecycleState']}"
                    for i in groups[0]["Instances"]
                ]
                log.info("  Instances: %s (%.0fs elapsed)", ", ".join(states), elapsed)

        except Exception as exc:
            elapsed = timeout - (deadline - time.monotonic())
            log.info("  API call failed (%.0fs elapsed): %s — retrying", elapsed, exc)

        if time.monotonic() >= deadline:
            break

        time.sleep(interval)

    raise TimeoutError(
        f"Cluster did not recover to {expected_count} InService instances in ASG {asg_name} "
        f"after {timeout}s. Check ASG activity and instance logs."
    )


def _drain_pipe(stream) -> None:
    """Read and discard plugin IPC bytes to prevent OS pipe buffer overflow."""
    try:
        while stream.read(4096):
            pass
    except Exception:
        pass


@contextlib.contextmanager
def ssm_port_forward(
    instance_id: str,
    remote_host: str,
    remote_port: int,
    local_port: int,
    region: str,
) -> Iterator[int]:
    """Open an SSM port-forward tunnel and yield local_port once traffic flows end-to-end.

    Requires the AWS Session Manager Plugin to be installed separately from the AWS CLI.
    """
    if shutil.which("session-manager-plugin") is None:
        raise RuntimeError(
            "AWS Session Manager Plugin is not installed. "
            "Install from: https://docs.aws.amazon.com/systems-manager/latest/userguide/"
            "session-manager-working-with-install-plugin.html"
        )

    cmd = [
        "aws", "ssm", "start-session",
        "--target", instance_id,
        "--document-name", "AWS-StartPortForwardingSessionToRemoteHost",
        "--parameters", f"host={remote_host},portNumber={remote_port},localPortNumber={local_port}",
        "--region", region,
    ]
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,   # must be PIPE: plugin uses stdout as IPC channel with the CLI
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    threading.Thread(target=_drain_pipe, args=(proc.stdout,), daemon=True).start()
    try:
        # Stage 1: wait for the local port to bind (plugin lifecycle step 1)
        deadline = time.monotonic() + 60.0
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("localhost", local_port), timeout=1):
                    break
            except (ConnectionRefusedError, OSError):
                if proc.poll() is not None:
                    stderr = proc.stderr.read().decode(errors="replace") if proc.stderr else ""
                    raise RuntimeError(f"SSM port-forward process exited early: {stderr}")
                time.sleep(1)
        else:
            raise TimeoutError(
                f"SSM tunnel to localhost:{local_port} did not open within 60s"
            )

        # With stdout=PIPE, the WebSocket channel is ready by the time the local port
        # binds. A short sleep covers any residual startup lag without probing the
        # tunnel (a partial-read probe sends a TCP RST that corrupts WebSocket state).
        # See worklog/FIX_SSM_WORK_LOG.md for the full investigation.
        time.sleep(3)
        yield local_port
    finally:
        # Kill the entire process group: `aws ssm start-session` spawns
        # `session-manager-plugin` as a grandchild. SIGTERM to the `aws`
        # process alone leaves the grandchild alive, holding the local port.
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()


def terminate_instance(session: boto3.Session, instance_id: str) -> None:
    """Terminate an EC2 instance. The ASG will launch a replacement."""
    ec2 = session.client("ec2")
    ec2.terminate_instances(InstanceIds=[instance_id])
    log.info("  Terminated instance %s", instance_id)


def wait_for_replacement_instance(
    session: boto3.Session,
    stack_name: str,
    resource_map: dict[str, str],
    *,
    exclude_instance: str | None = None,
    timeout: int = 600,
    interval: int = 15,
) -> str:
    """Poll the ASG until a new InService instance appears. Return its instance ID.

    If *exclude_instance* is given, ignore that ID (the just-terminated instance
    may briefly remain in the ASG).
    """
    asg_name = resource_map.get("Neo4jAutoScalingGroup")
    if not asg_name:
        raise RuntimeError(f"Neo4jAutoScalingGroup not found in stack {stack_name}")

    asg_client = session.client("autoscaling")
    deadline = time.monotonic() + timeout

    while True:
        try:
            groups = asg_client.describe_auto_scaling_groups(
                AutoScalingGroupNames=[asg_name]
            )["AutoScalingGroups"]

            if groups:
                for instance in groups[0]["Instances"]:
                    iid = instance["InstanceId"]
                    state = instance["LifecycleState"]
                    if state == "InService" and iid != exclude_instance:
                        elapsed = timeout - (deadline - time.monotonic())
                        log.info(
                            "  Replacement %s is InService (%.0fs elapsed)", iid, elapsed
                        )
                        return iid

                elapsed = timeout - (deadline - time.monotonic())
                states = [
                    f"{i['InstanceId']}={i['LifecycleState']}"
                    for i in groups[0]["Instances"]
                ]
                if states:
                    log.info("  Instances: %s (%.0fs elapsed)", ", ".join(states), elapsed)
                else:
                    log.info("  No instances in ASG yet (%.0fs elapsed)", elapsed)

        except Exception as exc:
            elapsed = timeout - (deadline - time.monotonic())
            log.info("  API call failed (%.0fs elapsed): %s — retrying", elapsed, exc)

        if time.monotonic() >= deadline:
            break

        time.sleep(interval)

    raise TimeoutError(
        f"No InService replacement instance in ASG {asg_name} after {timeout}s. "
        "Check ASG activity and instance logs."
    )
