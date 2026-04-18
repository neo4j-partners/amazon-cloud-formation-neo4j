#!/usr/bin/env bash
# ssm_check_sessions.sh — list active SSM sessions for a stack's instances
# Usage: ./ssm_check_sessions.sh [stack-name] [region]
#
# Shows all active SSM sessions for the instances in the given stack's ASG.
# Useful for checking whether a previous test run left orphan tunnels open.

set -euo pipefail

STACK_NAME="${1:-}"
REGION="${2:-us-east-1}"

if [[ -z "$STACK_NAME" ]]; then
  # Try to pick the most recent deploy file
  DEPLOY_FILE=$(ls -t "$(dirname "$0")/../.deploy/"*.txt 2>/dev/null | head -1 || true)
  if [[ -z "$DEPLOY_FILE" ]]; then
    echo "Usage: $0 <stack-name> [region]"
    exit 1
  fi
  STACK_NAME=$(grep '^StackName' "$DEPLOY_FILE" | awk -F'=' '{print $2}' | tr -d ' ')
  REGION=$(grep '^Region' "$DEPLOY_FILE" | awk -F'=' '{print $2}' | tr -d ' ')
  echo "Auto-detected: stack=$STACK_NAME region=$REGION"
fi

echo "=== Active SSM sessions for stack: $STACK_NAME ==="

# Get instance IDs from the ASG
ASG_NAME=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "StackResources[?LogicalResourceId=='Neo4jAutoScalingGroup'].PhysicalResourceId" \
  --output text)

echo "ASG: $ASG_NAME"

INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" \
  --output text)

echo "InService instances: $INSTANCE_IDS"
echo ""

for INSTANCE_ID in $INSTANCE_IDS; do
  echo "--- Sessions for $INSTANCE_ID ---"
  aws ssm describe-sessions \
    --state Active \
    --filters "key=Target,value=$INSTANCE_ID" \
    --region "$REGION" \
    --query "Sessions[*].{SessionId:SessionId,Owner:Owner,StartDate:StartDate,Status:Status}" \
    --output table 2>/dev/null || echo "  (none or error)"
done

echo ""
echo "=== Local ports in use ==="
lsof -i :7474 -i :7687 2>/dev/null || echo "  Ports 7474 and 7687 are free"
