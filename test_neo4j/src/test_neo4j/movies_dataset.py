"""Movies dataset: create, verify, and clean up the Matrix trilogy sample data."""

from __future__ import annotations

import logging

from test_neo4j.config import StackConfig
from test_neo4j.reporting import TestReporter

log = logging.getLogger(__name__)

MOVIES_CYPHER = """\
CREATE (TheMatrix:Movie {title:'The Matrix', released:1999, tagline:'Welcome to the Real World'})
CREATE (Keanu:Person {name:'Keanu Reeves', born:1964})
CREATE (Carrie:Person {name:'Carrie-Anne Moss', born:1967})
CREATE (Laurence:Person {name:'Laurence Fishburne', born:1961})
CREATE (Hugo:Person {name:'Hugo Weaving', born:1960})
CREATE (LillyW:Person {name:'Lilly Wachowski', born:1967})
CREATE (LanaW:Person {name:'Lana Wachowski', born:1965})
CREATE (JoelS:Person {name:'Joel Silver', born:1952})
CREATE
(Keanu)-[:ACTED_IN {roles:['Neo']}]->(TheMatrix),
(Carrie)-[:ACTED_IN {roles:['Trinity']}]->(TheMatrix),
(Laurence)-[:ACTED_IN {roles:['Morpheus']}]->(TheMatrix),
(Hugo)-[:ACTED_IN {roles:['Agent Smith']}]->(TheMatrix),
(LillyW)-[:DIRECTED]->(TheMatrix),
(LanaW)-[:DIRECTED]->(TheMatrix),
(JoelS)-[:PRODUCED]->(TheMatrix)

CREATE (Emil:Person {name:'Emil Eifrem', born:1978})
CREATE (Emil)-[:ACTED_IN {roles:['Emil']}]->(TheMatrix)

CREATE (TheMatrixReloaded:Movie {title:'The Matrix Reloaded', released:2003, tagline:'Free your mind'})
CREATE
(Keanu)-[:ACTED_IN {roles:['Neo']}]->(TheMatrixReloaded),
(Carrie)-[:ACTED_IN {roles:['Trinity']}]->(TheMatrixReloaded),
(Laurence)-[:ACTED_IN {roles:['Morpheus']}]->(TheMatrixReloaded),
(Hugo)-[:ACTED_IN {roles:['Agent Smith']}]->(TheMatrixReloaded),
(LillyW)-[:DIRECTED]->(TheMatrixReloaded),
(LanaW)-[:DIRECTED]->(TheMatrixReloaded),
(JoelS)-[:PRODUCED]->(TheMatrixReloaded)

CREATE (TheMatrixRevolutions:Movie {title:'The Matrix Revolutions', released:2003, tagline:'Everything that has a beginning has an end'})
CREATE
(Keanu)-[:ACTED_IN {roles:['Neo']}]->(TheMatrixRevolutions),
(Carrie)-[:ACTED_IN {roles:['Trinity']}]->(TheMatrixRevolutions),
(Laurence)-[:ACTED_IN {roles:['Morpheus']}]->(TheMatrixRevolutions),
(Hugo)-[:ACTED_IN {roles:['Agent Smith']}]->(TheMatrixRevolutions),
(LillyW)-[:DIRECTED]->(TheMatrixRevolutions),
(LanaW)-[:DIRECTED]->(TheMatrixRevolutions),
(JoelS)-[:PRODUCED]->(TheMatrixRevolutions)

WITH Keanu AS a
MATCH (a)-[:ACTED_IN]->(m)<-[:DIRECTED]-(d) RETURN a,m,d LIMIT 10;
"""

# Expected counts after loading the Movies dataset:
#   8 Person nodes + 3 Movie nodes = 11 nodes total
EXPECTED_NODE_COUNT = 11


def create_movies_dataset(config: StackConfig, reporter: TestReporter) -> bool:
    """Create the Movies dataset. Return True on success."""
    with reporter.test("Create Movies dataset") as ctx:
        try:
            with config.driver() as driver:
                driver.execute_query(MOVIES_CYPHER)
                ctx.pass_("Movies dataset created (3 movies, 8 people)")
                return True
        except Exception as exc:
            ctx.fail(f"Failed to create Movies dataset: {exc}")
            return False


def verify_movies_dataset(config: StackConfig, reporter: TestReporter) -> bool:
    """Verify the Movies dataset exists by counting nodes. Return True on success."""
    with reporter.test("Verify Movies dataset") as ctx:
        try:
            with config.driver() as driver:
                records, _, _ = driver.execute_query(
                    "MATCH (n) WHERE n:Movie OR n:Person RETURN count(n) AS cnt"
                )
                count = records[0]["cnt"]
                if count >= EXPECTED_NODE_COUNT:
                    ctx.pass_(f"Verified Movies dataset: {count} Movie/Person nodes found")
                    return True
                else:
                    ctx.fail(
                        f"Expected at least {EXPECTED_NODE_COUNT} Movie/Person nodes, "
                        f"found {count}"
                    )
                    return False
        except Exception as exc:
            ctx.fail(f"Failed to verify Movies dataset: {exc}")
            return False


def cleanup_movies_dataset(config: StackConfig) -> None:
    """Delete all Movie and Person nodes (best-effort, does not affect test results)."""
    try:
        with config.driver() as driver:
            driver.execute_query("MATCH (n) WHERE n:Movie OR n:Person DETACH DELETE n")
        log.info("  Cleaned up Movies dataset.\n")
    except Exception:
        log.warning("  Could not clean up Movies dataset (non-fatal).\n")
