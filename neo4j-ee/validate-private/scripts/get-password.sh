#!/usr/bin/env bash
# get-password.sh — Retrieve the Neo4j password from Secrets Manager
#
# Usage: ./scripts/get-password.sh [stack-name]
#
# Prints the password to stdout. Redirect to a variable:
#   PASSWORD=$(./scripts/get-password.sh)
#
# Exit codes: 0 = success, 1 = secret not found, 2 = IAM denied

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

OUTPUTS_FILE=$(resolve_stack "${1:-}")
STACK_NAME=$(read_field "$OUTPUTS_FILE" "StackName")
REGION=$(read_field "$OUTPUTS_FILE" "Region")
SECRET_NAME="neo4j/${STACK_NAME}/password"

echo "  Stack:  ${STACK_NAME}" >&2
echo "  Region: ${REGION}" >&2
echo "  Secret: ${SECRET_NAME}" >&2
echo "" >&2

aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${SECRET_NAME}" \
  --query SecretString \
  --output text
