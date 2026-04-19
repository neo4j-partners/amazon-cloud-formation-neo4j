"""Send Cypher queries to the Neo4j cluster via SSM RunShellScript on the operator bastion."""

from __future__ import annotations

import base64
import json
import logging
import time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from validate_private.config import StackConfig

log = logging.getLogger(__name__)

# Script that runs ON the bastion. It reads stack/region from argv, fetches
# credentials from Secrets Manager and NLB DNS from SSM Parameter Store using
# the bastion's own IAM role, then executes the Cypher query.
_BASTION_SCRIPT = """\
import sys
import json
import boto3
from neo4j import GraphDatabase

stack = sys.argv[1]
region = sys.argv[2]

data = json.load(sys.stdin)
cypher = data["cypher"]
params = data.get("params") or {}

sm = boto3.client("secretsmanager", region_name=region)
password = sm.get_secret_value(SecretId=f"neo4j/{stack}/password")["SecretString"]

ssm_client = boto3.client("ssm", region_name=region)
nlb = ssm_client.get_parameter(Name=f"/neo4j-ee/{stack}/nlb-dns")["Parameter"]["Value"]

driver = GraphDatabase.driver(f"neo4j://{nlb}:7687", auth=("neo4j", password))
try:
    result = driver.execute_query(cypher, parameters_=params)
    print(json.dumps([r.data() for r in result.records]))
except Exception as exc:
    print(json.dumps({"error": str(exc)}))
    sys.exit(1)
finally:
    driver.close()
"""


class BastionCommandError(RuntimeError):
    pass


class Neo4jQueryError(RuntimeError):
    pass


def run_cypher_on_bastion(
    config: "StackConfig",
    cypher: str,
    params: dict | None = None,
    timeout_s: int = 60,
) -> list[dict]:
    """Execute a Cypher query via SSM RunShellScript on the operator bastion.

    The bastion resolves the password from Secrets Manager and the NLB DNS from
    SSM Parameter Store using its own IAM role. Base64 encoding sidesteps all
    shell-quoting issues — the Cypher can contain single quotes, double quotes,
    backticks, or newlines without special handling.
    """
    import boto3
    from botocore.exceptions import ClientError

    b64_script = base64.b64encode(_BASTION_SCRIPT.encode()).decode()
    payload = json.dumps({"cypher": cypher, "params": params or {}})
    b64_payload = base64.b64encode(payload.encode()).decode()

    command = (
        f"echo {b64_script} | base64 -d > /tmp/vprun.py && "
        f"echo {b64_payload} | base64 -d | python3 /tmp/vprun.py "
        f"{config.stack_name} {config.region}"
    )

    session = boto3.Session(region_name=config.region)
    ssm = session.client("ssm")

    try:
        resp = ssm.send_command(
            InstanceIds=[config.bastion_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [command]},
        )
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        if code == "InvalidInstanceId":
            raise BastionCommandError(
                f"Bastion {config.bastion_id} is not SSM-registered. "
                "Run neo4j-ee/validate-private/scripts/preflight.sh to diagnose."
            ) from exc
        raise

    command_id = resp["Command"]["CommandId"]
    log.debug("SSM command %s dispatched to bastion %s", command_id, config.bastion_id)

    terminal = {"Success", "Failed", "Cancelled", "TimedOut"}
    deadline = time.monotonic() + timeout_s
    inv: dict = {}
    status = "Pending"

    while True:
        if time.monotonic() >= deadline:
            raise BastionCommandError(
                f"SSM command {command_id} did not complete within {timeout_s}s "
                f"(last status: {status})"
            )
        try:
            inv = ssm.get_command_invocation(
                CommandId=command_id,
                InstanceId=config.bastion_id,
            )
            status = inv["Status"]
            if status in terminal:
                break
        except ssm.exceptions.InvocationDoesNotExist:
            pass
        time.sleep(2)

    stdout = inv.get("StandardOutputContent", "").strip()
    stderr = inv.get("StandardErrorContent", "").strip()

    if status != "Success":
        raise BastionCommandError(
            f"SSM command failed (status={status}).\nstdout: {stdout}\nstderr: {stderr}"
        )

    try:
        result = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise BastionCommandError(
            f"Bastion returned non-JSON output: {stdout!r}"
        ) from exc

    if isinstance(result, dict) and "error" in result:
        raise Neo4jQueryError(f"Query failed on bastion: {result['error']}")

    if not isinstance(result, list):
        raise BastionCommandError(
            f"Bastion returned unexpected output (expected JSON array): {stdout!r}"
        )

    return result
