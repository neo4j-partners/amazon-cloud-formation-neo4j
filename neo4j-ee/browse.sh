#!/bin/bash
# browse.sh — Open the Neo4j Browser for a deployed EE stack via SSM port forwarding
#
# Usage:
#   ./browse.sh [stack-name]
#
# If stack-name is omitted, uses the most recently modified file in .deploy/.
# Forwards both port 7474 (Browser UI) and 7687 (Bolt) via SSM and prints login info.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/.deploy"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
STACK_ARG="${1:-}"

# ---------------------------------------------------------------------------
# Resolve the outputs file
# ---------------------------------------------------------------------------
if [ -n "${STACK_ARG}" ]; then
  OUTPUTS_FILE="${DEPLOY_DIR}/${STACK_ARG}.txt"
elif [ -d "${DEPLOY_DIR}" ]; then
  OUTPUTS_FILE=$(ls -t "${DEPLOY_DIR}"/*.txt 2>/dev/null | head -1 || true)
else
  OUTPUTS_FILE=""
fi

if [ -z "${OUTPUTS_FILE}" ] || [ ! -f "${OUTPUTS_FILE}" ]; then
  echo "ERROR: No deployment found." >&2
  if [ -n "${STACK_ARG}" ]; then
    echo "File not found: ${DEPLOY_DIR}/${STACK_ARG}.txt" >&2
  else
    echo "No .txt files in ${DEPLOY_DIR}/" >&2
  fi
  echo "Usage: $0 [stack-name]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helper: read a value from a "Key = Value" file
# ---------------------------------------------------------------------------
read_field() {
  grep "^${1}" "$OUTPUTS_FILE" | sed 's/^[^=]*= *//' | tr -d '\r'
}

REGION=$(read_field "Region")
BASTION_ID=$(read_field "Neo4jOperatorBastionId")
NLB_HOST=$(read_field "Neo4jInternalDNS")
USERNAME=$(read_field "Username")
PASSWORD=$(read_field "Password")
STACK_NAME=$(read_field "StackName")

echo "Stack:    ${STACK_NAME}"
echo "Region:   ${REGION}"
echo "Bastion:  ${BASTION_ID}"
echo ""
echo "Opening SSM port-forwards → localhost:7474 (Browser) and localhost:7687 (Bolt)"
echo ""
echo "Neo4j Browser: http://localhost:7474"
echo "Username: ${USERNAME}"
echo "Password: ${PASSWORD}"
echo ""
echo "Press Ctrl+C to stop the tunnels."
echo ""

# Kill both SSM sessions on exit
cleanup() {
  kill "${BOLT_PID}" 2>/dev/null || true
  wait "${BOLT_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

aws ssm start-session \
  --region "${REGION}" \
  --target "${BASTION_ID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${NLB_HOST},portNumber=7687,localPortNumber=7687" &
BOLT_PID=$!

aws ssm start-session \
  --region "${REGION}" \
  --target "${BASTION_ID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${NLB_HOST},portNumber=7474,localPortNumber=7474"
