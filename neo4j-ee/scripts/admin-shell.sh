#!/usr/bin/env bash
# admin-shell.sh — Open an interactive cypher-shell session via the operator bastion
#
# The password is resolved on the bastion using its IAM role — it never appears
# on the laptop or in CloudTrail. The SSM session stays open for the duration of
# the cypher-shell process.
#
# Usage: ./scripts/admin-shell.sh [stack-name]
# Prerequisite: AWS Session Manager Plugin installed (brew install --cask session-manager-plugin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

OUTPUTS_FILE=$(resolve_stack "${1:-}")
require_private_mode "$OUTPUTS_FILE"

STACK_NAME=$(read_field "$OUTPUTS_FILE" "StackName")
REGION=$(read_field "$OUTPUTS_FILE" "Region")
BASTION_ID=$(read_field "$OUTPUTS_FILE" "Neo4jOperatorBastionId")

echo "=== Neo4j Admin Shell ==="
echo ""
echo "  Stack:   ${STACK_NAME}"
echo "  Region:  ${REGION}"
echo "  Bastion: ${BASTION_ID}"
echo ""
echo "  Password is resolved on the bastion — not visible here or in CloudTrail."
echo "  Type ':exit' or press Ctrl-D to close the session."
echo ""

# Build the launcher script with STACK_NAME and REGION substituted on the laptop.
# The single-quoted heredoc prevents all bash expansion; placeholders are replaced by sed.
LAUNCHER=$(sed \
  -e "s|__STACK__|${STACK_NAME}|g" \
  -e "s|__REGION__|${REGION}|g" \
  << 'LAUNCHER_EOF'
#!/bin/bash
set -euo pipefail
export NEO4J_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id 'neo4j/__STACK__/password' \
  --query SecretString --output text --region '__REGION__')
NLB=$(aws ssm get-parameter \
  --name '/neo4j-ee/__STACK__/nlb-dns' \
  --query Parameter.Value --output text --region '__REGION__')
exec cypher-shell -a "neo4j://${NLB}:7687" -u neo4j -p "${NEO4J_PASSWORD}"
LAUNCHER_EOF
)

B64_LAUNCHER=$(printf '%s' "${LAUNCHER}" | base64 | tr -d '\n')

# Step 1: write the launcher to a file on the bastion via RunShellScript.
echo "  Preparing bastion..." >&2
CMD_ID=$(aws ssm send-command \
  --instance-ids "${BASTION_ID}" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"echo ${B64_LAUNCHER} | base64 -d > /tmp/neo4j-shell.sh && chmod +x /tmp/neo4j-shell.sh\"]" \
  --region "${REGION}" \
  --query "Command.CommandId" \
  --output text)

for i in $(seq 1 15); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "${CMD_ID}" \
    --instance-id "${BASTION_ID}" \
    --region "${REGION}" \
    --query "Status" \
    --output text 2>/dev/null || echo "Pending")
  [ "$STATUS" = "Success" ] && break
  if [[ "$STATUS" == "Failed" || "$STATUS" == "Cancelled" || "$STATUS" == "TimedOut" ]]; then
    echo "ERROR: Failed to prepare bastion (status=${STATUS})" >&2
    exit 1
  fi
  sleep 2
done

# Step 2: start an interactive session that runs the launcher.
exec aws ssm start-session \
  --target "${BASTION_ID}" \
  --region "${REGION}" \
  --document-name AWS-StartInteractiveCommand \
  --parameters '{"command": ["/tmp/neo4j-shell.sh"]}'
