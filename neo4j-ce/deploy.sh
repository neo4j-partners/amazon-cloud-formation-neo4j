#!/bin/bash
#
# Deploy the Neo4j Community Edition CloudFormation stack for local testing.
#
# Usage:
#   ./deploy.sh [ami-id]
#
# Stack name is auto-generated as test-standalone-<timestamp>.
# Password is randomly generated and saved to stack-outputs.txt.
#
# AMI resolution order:
#   1. First argument (ami-id)
#   2. marketplace/ami-id.txt (written by create-ami.sh)
#   3. Error — an AMI ID is required for local testing
#
# When deployed through the Marketplace console the ImageId parameter is
# resolved automatically via SSM. For local testing this script creates a
# temporary SSM parameter with the AMI ID (the CloudFormation parameter type
# is AWS::SSM::Parameter::Value and expects an SSM path, not a raw AMI ID).

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-marketplace}"

STACK_NAME="test-standalone-$(date +%s)"
TEMPLATE_BODY="file://neo4j.template.yaml"
REGION="us-east-1"
# Password must satisfy the template AllowedPattern (letters + numbers).
# openssl rand -base64 occasionally produces all-letter output, so append
# a random digit to guarantee the pattern matches.
Password="$(openssl rand -base64 12)$(( RANDOM % 10 ))"
InstallAPOC="yes"

# Resolve the AMI ID: CLI arg > ami-id.txt > error
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AMI_ID_FILE="${SCRIPT_DIR}/marketplace/ami-id.txt"

if [ -n "${1:-}" ]; then
  AMI_ID="$1"
elif [ -f "${AMI_ID_FILE}" ]; then
  AMI_ID="$(cat "${AMI_ID_FILE}")"
  echo "Using AMI from ${AMI_ID_FILE}: ${AMI_ID}"
else
  echo "ERROR: No AMI ID provided and ${AMI_ID_FILE} not found." >&2
  echo "Either pass an AMI ID as an argument or run create-ami.sh first." >&2
  exit 1
fi

# The ImageId parameter is type AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>,
# so CloudFormation expects an SSM parameter path, not a raw AMI ID.
# Create a temporary SSM parameter to hold the AMI ID for local testing.
SSM_PARAM_PATH="/neo4j-ce/test/${STACK_NAME}/ami-id"
echo "Creating SSM parameter ${SSM_PARAM_PATH} -> ${AMI_ID}..."
aws ssm put-parameter \
  --region "$REGION" \
  --name "${SSM_PARAM_PATH}" \
  --type String \
  --value "${AMI_ID}" \
  --overwrite > /dev/null

PARAMS="ParameterKey=Password,ParameterValue=${Password}"
PARAMS="${PARAMS} ParameterKey=InstallAPOC,ParameterValue=${InstallAPOC}"
PARAMS="${PARAMS} ParameterKey=ImageId,ParameterValue=${SSM_PARAM_PATH}"

echo "Creating stack ${STACK_NAME}..."
aws cloudformation create-stack \
  --capabilities CAPABILITY_IAM \
  --stack-name "$STACK_NAME" \
  --template-body "$TEMPLATE_BODY" \
  --region "$REGION" \
  --disable-rollback \
  --parameters $PARAMS

echo "Waiting for stack to complete (this takes a few minutes)..."
aws cloudformation wait stack-create-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "Stack created. Writing outputs to stack-outputs.txt..."
OUTPUTS_FILE="${SCRIPT_DIR}/stack-outputs.txt"

# CloudFormation outputs
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output text | while read -r key value; do
    printf "%-20s = %s\n" "$key" "$value"
  done | tee "${OUTPUTS_FILE}"

# Deploy context (values not in CloudFormation outputs)
{
  printf "%-20s = %s\n" "StackName" "$STACK_NAME"
  printf "%-20s = %s\n" "Region" "$REGION"
  printf "%-20s = %s\n" "Password" "$Password"
  printf "%-20s = %s\n" "InstallAPOC" "$InstallAPOC"
  printf "%-20s = %s\n" "SSMParamPath" "$SSM_PARAM_PATH"
  printf "%-20s = %s\n" "AmiId" "$AMI_ID"
} | tee -a "${OUTPUTS_FILE}"

echo ""
echo "Outputs saved to ${OUTPUTS_FILE}"
echo ""
echo "To test:     ./test-stack.sh"
echo "To tear down: ./teardown.sh"
