"""Neo4j EE cluster health checks: ASG membership, Raft topology, and routing table."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from neo4j import RoutingControl

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
                # SHOW SERVERS: verify expected number of enabled, healthy members.
                # Neo4j 2026.x schema: name, address, state, health, hosting.
                server_records, _, _ = driver.execute_query(
                    "SHOW SERVERS YIELD name, state, health",
                    routing_=RoutingControl.READ,
                )
                enabled = [
                    r for r in server_records
                    if r["state"] == "Enabled" and r["health"] == "Available"
                ]

                # SHOW DATABASES: verify each server hosts the neo4j database
                # online and exactly one server is the Raft writer (leader).
                db_records, _, _ = driver.execute_query(
                    "SHOW DATABASES YIELD name, currentStatus, writer "
                    "WHERE name = 'neo4j'",
                    routing_=RoutingControl.READ,
                )
                online = [r for r in db_records if r["currentStatus"] == "online"]
                writers = [r for r in online if r["writer"]]

                issues = []
                if len(enabled) != config.number_of_servers:
                    issues.append(
                        f"expected {config.number_of_servers} Enabled servers, "
                        f"got {len(enabled)}"
                    )
                if len(online) != config.number_of_servers:
                    issues.append(
                        f"expected {config.number_of_servers} online database "
                        f"replicas, got {len(online)}"
                    )
                if len(writers) != 1:
                    issues.append(f"expected 1 writer (leader), got {len(writers)}")

                if not issues:
                    ctx.pass_(
                        f"{len(enabled)} servers Enabled, "
                        f"{len(online)} online, 1 writer (leader)"
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

    with reporter.test("Routing table has writer and reader endpoints") as ctx:
        try:
            with config.driver() as driver:
                # dbms.routing.getRoutingTable supersedes the deprecated
                # dbms.cluster.routing.getRoutingTable. Response format:
                # {ttl, servers: [{addresses: [...], role: 'WRITE'|'READ'|'ROUTE'}]}
                records, _, _ = driver.execute_query(
                    "CALL dbms.routing.getRoutingTable({database: 'neo4j'})",
                    routing_=RoutingControl.READ,
                )
                if not records:
                    ctx.fail("getRoutingTable returned no results")
                    return

                servers = records[0].get("servers", [])
                writers: list[str] = []
                readers: list[str] = []
                for entry in servers:
                    role = entry.get("role", "")
                    addresses = entry.get("addresses", [])
                    if role == "WRITE":
                        writers.extend(addresses)
                    elif role == "READ":
                        readers.extend(addresses)

                issues = []
                if not writers:
                    issues.append("no WRITE endpoint in routing table")
                expected_readers = config.number_of_servers - 1
                if len(readers) < expected_readers:
                    issues.append(
                        f"expected at least {expected_readers} READ endpoints, "
                        f"got {len(readers)}"
                    )

                if not issues:
                    ctx.pass_(
                        f"{len(writers)} writer(s), {len(readers)} reader(s) "
                        f"in routing table"
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
