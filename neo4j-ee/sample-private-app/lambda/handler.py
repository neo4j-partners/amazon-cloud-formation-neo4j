import json
import os

import boto3
from neo4j import GraphDatabase
from neo4j.exceptions import AuthError

ssm = boto3.client("ssm")
sm = boto3.client("secretsmanager")

_driver = None


def _init_driver():
    nlb_dns = ssm.get_parameter(Name=os.environ["NEO4J_SSM_NLB_PATH"])["Parameter"]["Value"]
    password = sm.get_secret_value(SecretId=os.environ["NEO4J_SECRET_ARN"])["SecretString"]
    return GraphDatabase.driver(f"neo4j+s://{nlb_dns}:7687", auth=("neo4j", password))


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
