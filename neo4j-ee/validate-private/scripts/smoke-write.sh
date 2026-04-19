#!/usr/bin/env bash
# smoke-write.sh — Run N write operations through the cluster via the operator bastion
#
# Confirms server-side routing and write availability on a fresh stack before
# relying on it for real traffic. Each iteration creates and immediately deletes
# a transient node; no permanent data is written.
#
# (2/3)^20 ≈ 3e-4 — at N=20, a coin-flip routing regression is effectively certain
# to produce at least one failure, making this a reliable regression check.
#
# Usage:
#   ./scripts/smoke-write.sh [stack-name] [iterations=20]
# Typical runtime: ~60s at N=20.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

OUTPUTS_FILE=$(resolve_stack "${1:-}")
require_private_mode "$OUTPUTS_FILE"

ITERATIONS="${2:-20}"
STACK_NAME=$(read_field "$OUTPUTS_FILE" "StackName")
REGION=$(read_field "$OUTPUTS_FILE" "Region")
BASTION_ID=$(read_field "$OUTPUTS_FILE" "Neo4jOperatorBastionId")

echo "=== Smoke Write Test ==="
echo ""
echo "  Stack:      ${STACK_NAME}"
echo "  Region:     ${REGION}"
echo "  Bastion:    ${BASTION_ID}"
echo "  Iterations: ${ITERATIONS}"
echo ""

BASTION_SCRIPT=$(cat << 'SCRIPT_EOF'
import sys, json, boto3
from neo4j import GraphDatabase

stack = sys.argv[1]
region = sys.argv[2]
n = int(sys.argv[3])

sm = boto3.client("secretsmanager", region_name=region)
password = sm.get_secret_value(SecretId=f"neo4j/{stack}/password")["SecretString"]

ssm_client = boto3.client("ssm", region_name=region)
nlb = ssm_client.get_parameter(Name=f"/neo4j-ee/{stack}/nlb-dns")["Parameter"]["Value"]

driver = GraphDatabase.driver(f"neo4j://{nlb}:7687", auth=("neo4j", password))
successes = 0
failures = 0
try:
    for i in range(1, n + 1):
        try:
            driver.execute_query("CREATE (n:_SmokeWrite) DELETE n")
            successes += 1
            print(f"  [{i}/{n}] OK", flush=True)
        except Exception as exc:
            failures += 1
            print(f"  [{i}/{n}] FAIL: {exc}", flush=True)
finally:
    driver.close()

print(f"\nResult: {successes}/{n} succeeded", flush=True)
if failures > 0:
    sys.exit(1)
SCRIPT_EOF
)

B64_SCRIPT=$(printf '%s' "${BASTION_SCRIPT}" | base64 | tr -d '\n')

CMD_1="echo ${B64_SCRIPT} | base64 -d > /tmp/vpsmoke.py"
CMD_2="python3 /tmp/vpsmoke.py ${STACK_NAME} ${REGION} ${ITERATIONS}"

CMD_ID=$(aws ssm send-command \
  --instance-ids "${BASTION_ID}" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"${CMD_1}\",\"${CMD_2}\"]" \
  --region "${REGION}" \
  --query "Command.CommandId" \
  --output text)

echo "  SSM command: ${CMD_ID}"
echo "  Waiting (est. ~$((ITERATIONS * 3))s)..."
echo ""

TIMEOUT_ITERS=$(( ITERATIONS * 5 + 30 ))
for i in $(seq 1 "${TIMEOUT_ITERS}"); do
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
    echo "Smoke write test PASSED."
    exit 0
  fi

  if [[ "$STATUS" == "Failed" || "$STATUS" == "Cancelled" || "$STATUS" == "TimedOut" ]]; then
    echo "ERROR: Smoke write test FAILED (status=${STATUS})" >&2
    aws ssm get-command-invocation \
      --command-id "${CMD_ID}" \
      --instance-id "${BASTION_ID}" \
      --region "${REGION}" \
      --query "StandardOutputContent" \
      --output text >&2
    aws ssm get-command-invocation \
      --command-id "${CMD_ID}" \
      --instance-id "${BASTION_ID}" \
      --region "${REGION}" \
      --query "StandardErrorContent" \
      --output text >&2
    exit 1
  fi
  sleep 2
done

echo "ERROR: Timed out waiting for smoke write test to complete." >&2
exit 1
