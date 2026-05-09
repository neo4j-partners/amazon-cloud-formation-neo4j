#!/usr/bin/env bash
# ssm_check_sessions.sh — list active SSM sessions for a stack's instances
# Usage: ./ssm_check_sessions.sh [stack-name]
#
# Shows all active SSM sessions for the instances in the given stack's ASG.
# Useful for checking whether a previous test run left orphan tunnels open.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

OUTPUTS_FILE=$(resolve_stack "${1:-}")
require_private_mode "$OUTPUTS_FILE"

STACK_NAME=$(read_field "$OUTPUTS_FILE" "StackName")
REGION=$(read_field "$OUTPUTS_FILE" "Region")
BASTION_ID=$(read_field "$OUTPUTS_FILE" "Neo4jOperatorBastionId")

echo "=== Active SSM sessions for stack: $STACK_NAME ==="

INSTANCE_IDS=()
for key in Neo4jNode1ASGName Neo4jNode2ASGName Neo4jNode3ASGName; do
  ASG_NAME=$(read_field "$OUTPUTS_FILE" "$key" || true)
  [ -n "$ASG_NAME" ] || continue

  echo "${key}: ${ASG_NAME}"
  while IFS= read -r instance_id; do
    [ -n "$instance_id" ] && [ "$instance_id" != "None" ] && INSTANCE_IDS+=("$instance_id")
  done < <(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
    --output text | tr '\t' '\n')
done

INSTANCE_IDS+=("$BASTION_ID")

echo "Instances: ${INSTANCE_IDS[*]}"
echo ""

for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
  echo "--- Sessions for $INSTANCE_ID ---"
  SESSION_OUTPUT=$(aws ssm describe-sessions \
    --state Active \
    --filters "key=Target,value=$INSTANCE_ID" \
    --region "$REGION" \
    --query "Sessions[*].{SessionId:SessionId,Owner:Owner,StartDate:StartDate,Status:Status}" \
    --output table 2>/dev/null || true)
  if [ -n "$SESSION_OUTPUT" ]; then
    echo "$SESSION_OUTPUT"
  else
    echo "  (none)"
  fi
done

echo ""
echo "=== Local ports in use ==="
lsof -i :7473 -i :7687 2>/dev/null || echo "  Ports 7473 and 7687 are free"
