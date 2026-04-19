#!/usr/bin/env bash
# run-cypher.sh — Execute a Cypher query on the Neo4j cluster via the operator bastion
#
# Prints JSON result rows to stdout. Credentials are resolved on the bastion.
#
# Usage:
#   ./scripts/run-cypher.sh '<cypher>'                        # most recent deployment
#   ./scripts/run-cypher.sh [stack-name] '<cypher>'           # specific stack
#
# Examples:
#   ./scripts/run-cypher.sh "CALL dbms.components() YIELD name, versions RETURN name, versions"
#   ./scripts/run-cypher.sh test-ee-123 "MATCH (n) RETURN count(n) AS total"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# Positional arg dispatch: 1 arg = cypher only; 2+ args = stack + cypher
if [ $# -eq 0 ]; then
  echo "Usage: $0 [stack-name] '<cypher>'" >&2
  exit 1
elif [ $# -eq 1 ]; then
  STACK_ARG=""
  CYPHER="$1"
else
  STACK_ARG="$1"
  CYPHER="$2"
fi

OUTPUTS_FILE=$(resolve_stack "${STACK_ARG}")
require_private_mode "$OUTPUTS_FILE"

STACK_NAME=$(read_field "$OUTPUTS_FILE" "StackName")
REGION=$(read_field "$OUTPUTS_FILE" "Region")
BASTION_ID=$(read_field "$OUTPUTS_FILE" "Neo4jOperatorBastionId")

echo "  Stack:  ${STACK_NAME}" >&2
echo "  Region: ${REGION}" >&2
echo "" >&2

# Build the bastion Python runner script using a quoted heredoc (no expansion).
BASTION_SCRIPT=$(cat << 'SCRIPT_EOF'
import sys, json, boto3
from neo4j import GraphDatabase

stack = sys.argv[1]
region = sys.argv[2]
data = json.load(sys.stdin)
cypher = data["cypher"]

sm = boto3.client("secretsmanager", region_name=region)
password = sm.get_secret_value(SecretId=f"neo4j/{stack}/password")["SecretString"]

ssm_client = boto3.client("ssm", region_name=region)
nlb = ssm_client.get_parameter(Name=f"/neo4j-ee/{stack}/nlb-dns")["Parameter"]["Value"]

driver = GraphDatabase.driver(f"neo4j://{nlb}:7687", auth=("neo4j", password))
try:
    result = driver.execute_query(cypher)
    print(json.dumps([r.data() for r in result.records]))
except Exception as exc:
    print(json.dumps({"error": str(exc)}), file=sys.stderr)
    sys.exit(1)
finally:
    driver.close()
SCRIPT_EOF
)

# Build JSON payload with the Cypher properly escaped.
# python3 is available on macOS and the uv environment; used only for JSON escaping.
PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'cypher':sys.argv[1]}))" "${CYPHER}")

B64_SCRIPT=$(printf '%s' "${BASTION_SCRIPT}" | base64 | tr -d '\n')
B64_PAYLOAD=$(printf '%s' "${PAYLOAD}" | base64 | tr -d '\n')

CMD_1="echo ${B64_SCRIPT} | base64 -d > /tmp/vprun.py"
CMD_2="echo ${B64_PAYLOAD} | base64 -d | python3 /tmp/vprun.py ${STACK_NAME} ${REGION}"

CMD_ID=$(aws ssm send-command \
  --instance-ids "${BASTION_ID}" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"${CMD_1}\",\"${CMD_2}\"]" \
  --region "${REGION}" \
  --query "Command.CommandId" \
  --output text)

echo "  SSM command: ${CMD_ID}" >&2

for i in $(seq 1 30); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "${CMD_ID}" \
    --instance-id "${BASTION_ID}" \
    --region "${REGION}" \
    --query "Status" \
    --output text 2>/dev/null || echo "Pending")

  if [ "$STATUS" = "Success" ]; then
    aws ssm get-command-invocation \
      --command-id "${CMD_ID}" \
      --instance-id "${BASTION_ID}" \
      --region "${REGION}" \
      --query "StandardOutputContent" \
      --output text
    exit 0
  fi

  if [[ "$STATUS" == "Failed" || "$STATUS" == "Cancelled" || "$STATUS" == "TimedOut" ]]; then
    echo "ERROR: Command failed (status=${STATUS})" >&2
    aws ssm get-command-invocation \
      --command-id "${CMD_ID}" \
      --instance-id "${BASTION_ID}" \
      --region "${REGION}" \
      --query "StandardErrorContent" \
      --output text >&2
    exit 1
  fi
done

echo "ERROR: Timed out waiting for SSM command to complete." >&2
exit 1
