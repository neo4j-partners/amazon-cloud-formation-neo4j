"""Neo4j EE cluster health checks: ASG membership, Raft topology, and routing table."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from neo4j import RoutingControl

from test_neo4j.aws_helpers import get_all_ee_asg_instance_ids
from test_neo4j.config import StackConfig
from test_neo4j.reporting import TestReporter

if TYPE_CHECKING:
    import boto3

log = logging.getLogger(__name__)


def check_all_nodes_inservice(
    session: boto3.Session,
    config: StackConfig,
    reporter: TestReporter,
    resource_map: dict[str, str],
) -> None:
    """Verify exactly one InService instance exists in each node's ASG."""
    asg_client = session.client("autoscaling")
    for n in range(1, config.number_of_servers + 1):
        asg_logical_id = f"Neo4jNode{n}ASG"
        asg_name = resource_map.get(asg_logical_id)
        with reporter.test(f"ASG node {n} has one InService instance") as ctx:
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
                inservice = [
                    i for i in groups[0]["Instances"]
                    if i["LifecycleState"] == "InService"
                ]
                if len(inservice) == 1:
                    ctx.pass_(f"{asg_name}: {inservice[0]['InstanceId']} InService")
                else:
                    states = [
                        f"{i['InstanceId']}={i['LifecycleState']}"
                        for i in groups[0]["Instances"]
                    ]
                    ctx.fail(
                        f"{asg_name}: expected 1 InService instance, "
                        f"got {len(inservice)}. States: {', '.join(states) or 'none'}"
                    )
            except Exception as exc:
                ctx.fail(f"Failed to describe ASG {asg_name}: {exc}")


def check_cluster_topology(
    config: StackConfig,
    reporter: TestReporter,
) -> None:
    """Verify Raft cluster has the expected number of enabled servers with correct roles.

    Skipped for single-node stacks (no Raft election occurs).
    """
    if config.number_of_servers == 1:
        log.info("  Skipping cluster topology check (single-node deployment)\n")
        return

    with reporter.test("Cluster topology (SHOW SERVERS)") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "SHOW SERVERS YIELD serverId, role, currentStatus",
                    routing_=RoutingControl.READ,
                )
                enabled = [r for r in records if r["currentStatus"] == "Enabled"]
                primaries = [r for r in enabled if r["role"] == "PRIMARY"]
                secondaries = [r for r in enabled if r["role"] == "SECONDARY"]

                issues = []
                if len(enabled) != config.number_of_servers:
                    issues.append(
                        f"expected {config.number_of_servers} Enabled servers, "
                        f"got {len(enabled)}"
                    )
                if config.number_of_servers == 3:
                    if len(primaries) != 1:
                        issues.append(f"expected 1 PRIMARY, got {len(primaries)}")
                    if len(secondaries) != 2:
                        issues.append(f"expected 2 SECONDARY, got {len(secondaries)}")

                if not issues:
                    ctx.pass_(
                        f"{len(enabled)} servers Enabled: "
                        f"{len(primaries)} PRIMARY, {len(secondaries)} SECONDARY"
                    )
                else:
                    ctx.fail("; ".join(issues))
        except Exception as exc:
            ctx.fail(f"SHOW SERVERS failed: {exc}")


def check_routing_table(
    config: StackConfig,
    reporter: TestReporter,
    session: boto3.Session,
    resource_map: dict[str, str],
) -> None:
    """Verify routing table writer/reader endpoints match cluster EC2 private IPs.

    Skipped for single-node stacks.
    """
    if config.number_of_servers == 1:
        log.info("  Skipping routing table check (single-node deployment)\n")
        return

    with reporter.test("Routing table endpoints match EC2 private IPs") as ctx:
        try:
            node_pairs = get_all_ee_asg_instance_ids(
                session, config.stack_name, resource_map, config.number_of_servers
            )
            instance_ids = [iid for _, iid in node_pairs]
            ec2 = session.client("ec2")
            resp = ec2.describe_instances(InstanceIds=instance_ids)
            cluster_ips: set[str] = set()
            for reservation in resp["Reservations"]:
                for inst in reservation["Instances"]:
                    private_ip = inst.get("PrivateIpAddress")
                    if private_ip:
                        cluster_ips.add(private_ip)

            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "CALL dbms.cluster.routing.getRoutingTable({database: 'neo4j'})",
                    routing_=RoutingControl.READ,
                )
                if not records:
                    ctx.fail("getRoutingTable returned no results")
                    return

                row = records[0]
                writers = row.get("writers", [])
                readers = row.get("readers", [])

                issues = []
                if not writers:
                    issues.append("no writer endpoint in routing table")
                if len(readers) < 2:
                    issues.append(f"expected at least 2 reader endpoints, got {len(readers)}")

                all_endpoints = writers + readers
                rogue = []
                for endpoint in all_endpoints:
                    ip = endpoint.split(":")[0] if ":" in endpoint else endpoint
                    if ip not in cluster_ips:
                        rogue.append(endpoint)

                if rogue:
                    issues.append(
                        f"endpoints not matching any cluster EC2 private IP: {rogue} "
                        f"(cluster IPs: {sorted(cluster_ips)})"
                    )

                if not issues:
                    ctx.pass_(
                        f"{len(writers)} writer(s), {len(readers)} reader(s); "
                        f"all IPs in cluster ({sorted(cluster_ips)})"
                    )
                else:
                    ctx.fail("; ".join(issues))

        except Exception as exc:
            ctx.fail(f"Routing table check failed: {exc}")


def run_cluster_checks(
    config: StackConfig,
    reporter: TestReporter,
    session: boto3.Session,
    resource_map: dict[str, str],
) -> None:
    """Run all EE cluster health checks."""
    check_all_nodes_inservice(session, config, reporter, resource_map)
    check_cluster_topology(config, reporter)
    check_routing_table(config, reporter, session, resource_map)
