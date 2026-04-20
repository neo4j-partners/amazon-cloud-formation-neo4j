import json
import logging
import os
import random
import time

import boto3
from neo4j import GraphDatabase
from neo4j.exceptions import AuthError

log = logging.getLogger(__name__)

ssm = boto3.client("ssm")
sm = boto3.client("secretsmanager")

_driver = None
_BOLT_TLS = os.environ.get("NEO4J_BOLT_TLS") == "true"
_BOLT_SCHEME = "neo4j+ssc" if _BOLT_TLS else "neo4j"


def _init_driver():
    nlb_dns = ssm.get_parameter(Name=os.environ["NEO4J_SSM_NLB_PATH"])["Parameter"]["Value"]
    password = sm.get_secret_value(SecretId=os.environ["NEO4J_SECRET_ARN"])["SecretString"]
    return GraphDatabase.driver(f"{_BOLT_SCHEME}://{nlb_dns}:7687", auth=("neo4j", password))


def _get_driver():
    global _driver
    if _driver is None:
        _driver = _init_driver()
    return _driver


def _reset_driver():
    global _driver
    if _driver is not None:
        _driver.close()
    _driver = _init_driver()
    return _driver


_MERGE_FINTECH = """
MERGE (c1:Customer {id: 'c1', name: 'Alice Chen', segment: 'SMB'})
MERGE (c2:Customer {id: 'c2', name: 'Bob Patel', segment: 'Enterprise'})
MERGE (c3:Customer {id: 'c3', name: 'Carol Wu', segment: 'SMB'})

MERGE (a1:Account {id: 'acc1', type: 'checking', balance: 84200.00})
MERGE (a2:Account {id: 'acc2', type: 'checking', balance: 210000.00})
MERGE (a3:Account {id: 'acc3', type: 'savings',  balance: 55000.00})

MERGE (m1:Merchant {id: 'm1', name: 'StripePayments', category: 'payments'})
MERGE (m2:Merchant {id: 'm2', name: 'AmazonAWS',      category: 'cloud'})
MERGE (m3:Merchant {id: 'm3', name: 'WeWorkSpaces',   category: 'office'})

MERGE (t1:Transaction {id: 'txn1', amount: 2400.00,  currency: 'USD', ts: '2026-04-01'})
MERGE (t2:Transaction {id: 'txn2', amount: 18700.00, currency: 'USD', ts: '2026-04-02'})
MERGE (t3:Transaction {id: 'txn3', amount: 6500.00,  currency: 'USD', ts: '2026-04-03'})

MERGE (c1)-[:OWNS]->(a1)
MERGE (c2)-[:OWNS]->(a2)
MERGE (c3)-[:OWNS]->(a3)

MERGE (a1)-[:ORIGINATED_FROM]->(t1)
MERGE (a2)-[:ORIGINATED_FROM]->(t2)
MERGE (a3)-[:ORIGINATED_FROM]->(t3)

MERGE (t1)-[:AT]->(m1)
MERGE (t2)-[:AT]->(m2)
MERGE (t3)-[:AT]->(m3)
"""


def lambda_handler(event, context):
    try:
        driver = _get_driver()
        return _run(driver)
    except AuthError:
        driver = _reset_driver()
        return _run(driver)


def _run(driver):
    with driver.session(database="neo4j") as session:
        result = session.run(_MERGE_FINTECH)
        summary = result.consume()
        nodes_created = summary.counters.nodes_created
        rels_created = summary.counters.relationships_created

        edition_row = session.run(
            "CALL dbms.components() YIELD name, versions, edition"
        ).single()
        edition = edition_row["edition"] if edition_row else "unknown"

        routing_rows = session.run(
            "CALL dbms.routing.getRoutingTable({}, 'neo4j')"
        ).data()

        graph_sample = session.run(
            """
            MATCH (c:Customer)-[:OWNS]->(a:Account)-[:ORIGINATED_FROM]->(t:Transaction)-[:AT]->(m:Merchant)
            RETURN c.name AS customer, a.type AS account_type, t.amount AS amount, m.name AS merchant
            ORDER BY t.ts
            """
        ).data()

    with driver.session(database="system") as sys_session:
        servers = sys_session.run("SHOW SERVERS").data()

    writers = 0
    readers = 0
    for row in routing_rows:
        for server in row.get("servers", []):
            role = server.get("role")
            if role == "WRITE":
                writers += 1
            elif role == "READ":
                readers += len(server.get("addresses", []))

    body = {
        "tls_enabled": _BOLT_TLS,
        "bolt_scheme": _BOLT_SCHEME,
        "edition": edition,
        "nodes_created": nodes_created,
        "relationships_created": rels_created,
        "graph_sample": graph_sample,
        "servers": [
            {
                "name": s.get("name", s.get("address", "")),
                "state": s.get("state", ""),
                "health": s.get("health", ""),
            }
            for s in servers
        ],
        "routing_table": {
            "writers": writers,
            "readers": readers,
        },
    }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, indent=2),
    }


# ---------------------------------------------------------------------------
# Resilience handler: stop a follower via SSM and verify it rejoins.
# ---------------------------------------------------------------------------

_ec2 = boto3.client("ec2")
_ssm = boto3.client("ssm")

STOP_WAIT_TIMEOUT_S = 90
START_WAIT_TIMEOUT_S = 180
POLL_INTERVAL_S = 3


def resilience_handler(event, context):
    try:
        driver = _get_driver()
        return _resilience(driver)
    except AuthError:
        driver = _reset_driver()
        return _resilience(driver)


def _resilience(driver):
    ee_stack = os.environ["NEO4J_STACK_NAME"]
    ee_stack_id = os.environ["NEO4J_STACK_ID"]

    with driver.session(database="system") as s:
        preflight = s.run("SHOW SERVERS").data()
    unhealthy = [r for r in preflight if r.get("health") != "Available"]
    if unhealthy:
        raise RuntimeError(f"Cluster is already degraded; refusing to run test: {unhealthy}")

    followers, leader = _cluster_roles(driver)
    if not followers:
        raise RuntimeError("No FOLLOWER members found in dbms.cluster.overview()")

    instance_ids = _neo4j_instance_ids(ee_stack_id)
    if len(instance_ids) < 2:
        raise RuntimeError(f"Expected >=2 Neo4j instances, found {len(instance_ids)}")

    uuid_by_instance = _read_server_ids(instance_ids)
    follower_instances = [i for i, u in uuid_by_instance.items() if u in followers]
    if not follower_instances:
        raise RuntimeError("Could not map any instance to a FOLLOWER UUID")

    target_instance = random.choice(follower_instances)
    target_uuid = uuid_by_instance[target_instance]

    log.info("Target follower: instance=%s server=%s", target_instance, target_uuid)

    t0 = time.time()
    _ssm_run(target_instance, "systemctl stop neo4j")
    time_to_stop_issued = round(time.time() - t0, 2)

    t1 = time.time()
    stop_health = _wait_for_health(driver, target_uuid, {"Unavailable", "Down", "Unknown"}, STOP_WAIT_TIMEOUT_S)
    time_to_unavailable = round(time.time() - t1, 2)

    t2 = time.time()
    _ssm_run(target_instance, "systemctl start neo4j")
    time_to_start_issued = round(time.time() - t2, 2)

    t3 = time.time()
    start_health = _wait_for_health(driver, target_uuid, {"Available"}, START_WAIT_TIMEOUT_S)
    time_to_available = round(time.time() - t3, 2)

    with driver.session(database="system") as s:
        final_servers = s.run("SHOW SERVERS").data()

    body = {
        "ee_stack": ee_stack,
        "target_instance_id": target_instance,
        "target_server_uuid": target_uuid,
        "leader_server_uuid": leader,
        "time_to_stop_issued_s": time_to_stop_issued,
        "time_to_unavailable_s": time_to_unavailable,
        "observed_stop_health": stop_health,
        "time_to_start_issued_s": time_to_start_issued,
        "time_to_available_s": time_to_available,
        "observed_start_health": start_health,
        "final_servers": [
            {
                "name": s.get("name", ""),
                "state": s.get("state", ""),
                "health": s.get("health", ""),
            }
            for s in final_servers
        ],
    }
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, indent=2),
    }


def _cluster_roles(driver):
    with driver.session(database="system") as s:
        rows = s.run("CALL dbms.cluster.overview()").data()
    followers = []
    leader = None
    for r in rows:
        role = (r.get("databases") or {}).get("neo4j")
        sid = r.get("id")
        if role == "FOLLOWER":
            followers.append(sid)
        elif role == "LEADER":
            leader = sid
    return followers, leader


def _neo4j_instance_ids(ee_stack_id):
    # EE ASG propagates tag "StackID" = the full CFN stack ARN onto each instance.
    resp = _ec2.describe_instances(
        Filters=[
            {"Name": "tag:StackID", "Values": [ee_stack_id]},
            {"Name": "tag:Role", "Values": ["neo4j-cluster-node"]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    return [i["InstanceId"] for r in resp["Reservations"] for i in r["Instances"]]


def _read_server_ids(instance_ids):
    cmd_id = _ssm.send_command(
        InstanceIds=instance_ids,
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": ["cat /var/lib/neo4j/data/server_id"]},
    )["Command"]["CommandId"]

    mapping = {}
    deadline = time.time() + 60
    pending = set(instance_ids)
    while pending and time.time() < deadline:
        time.sleep(POLL_INTERVAL_S)
        for iid in list(pending):
            try:
                inv = _ssm.get_command_invocation(CommandId=cmd_id, InstanceId=iid)
            except _ssm.exceptions.InvocationDoesNotExist:
                continue
            status = inv["Status"]
            if status in ("Success", "Failed", "Cancelled", "TimedOut"):
                pending.discard(iid)
                if status == "Success":
                    mapping[iid] = inv["StandardOutputContent"].strip()
    if not mapping:
        raise RuntimeError("SSM read of /var/lib/neo4j/data/server_id returned no output")
    return mapping


def _ssm_run(instance_id, command):
    cmd_id = _ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [command]},
    )["Command"]["CommandId"]
    deadline = time.time() + 60
    while time.time() < deadline:
        time.sleep(POLL_INTERVAL_S)
        try:
            inv = _ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
        except _ssm.exceptions.InvocationDoesNotExist:
            continue
        if inv["Status"] == "Success":
            return
        if inv["Status"] in ("Failed", "Cancelled", "TimedOut"):
            raise RuntimeError(f"SSM '{command}' on {instance_id} ended {inv['Status']}: {inv.get('StandardErrorContent','')}")
    raise TimeoutError(f"SSM '{command}' on {instance_id} did not complete in 60s")


def _wait_for_health(driver, server_uuid, wanted, timeout_s):
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        try:
            with driver.session(database="system") as s:
                rows = s.run("SHOW SERVERS").data()
            for r in rows:
                if r.get("name") == server_uuid:
                    last = r.get("health")
                    if last in wanted:
                        return last
                    break
        except Exception as e:
            last = f"query-error: {e.__class__.__name__}"
        time.sleep(POLL_INTERVAL_S)
    raise TimeoutError(f"Server {server_uuid} health did not reach {wanted} within {timeout_s}s (last={last})")
