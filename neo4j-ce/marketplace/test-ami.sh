#!/bin/bash
# test-ami.sh — Verify a CE Marketplace base AMI via SSM Run Command
#
# Launches a temporary instance from the AMI, runs verification commands
# over SSM (no SSH key or port 22 required), reports pass/fail, and
# cleans up.
#
# The CE AMI is a base OS image only (SSH hardening + OS patches).
# Neo4j is installed at deploy time from yum.neo4j.com, so this script
# only verifies the base image properties.
#
# Prerequisites:
#   - AWS CLI configured with the marketplace profile (neo4j-marketplace account)
#   - The AMI must exist in us-east-1
#
# Usage:
#   AWS_PROFILE=marketplace ./test-ami.sh [ami-id]
#
# If ami-id is omitted, reads from ami-id.txt (written by create-ami.sh).
#
# Example:
#   AWS_PROFILE=marketplace ./test-ami.sh ami-089ef8c9f4da68869

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REGION="us-east-1"
EXPECTED_ACCOUNT="385155106615"
INSTANCE_TYPE="t3.medium"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve AMI ID: argument > ami-id.txt
if [ -n "${1:-}" ]; then
  AMI_ID="$1"
elif [ -f "${SCRIPT_DIR}/ami-id.txt" ]; then
  AMI_ID=$(cat "${SCRIPT_DIR}/ami-id.txt")
else
  echo "ERROR: No AMI ID provided and ${SCRIPT_DIR}/ami-id.txt not found."
  echo "Usage: AWS_PROFILE=marketplace $0 [ami-id]"
  echo ""
  echo "Either pass an AMI ID as an argument or run create-ami.sh first"
  echo "(it writes the AMI ID to ami-id.txt automatically)."
  exit 1
fi

# Tags for resources created by this script
INSTANCE_TAGS="ResourceType=instance,Tags=[{Key=Name,Value=neo4j-ce-ami-test},{Key=Purpose,Value=marketplace-ami-test}]"

# ---------------------------------------------------------------------------
# Preflight: verify AWS account
# ---------------------------------------------------------------------------
echo "=== Neo4j CE AMI Tester ==="
echo ""
echo "Verifying AWS identity..."

CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
  echo "ERROR: Failed to call sts get-caller-identity."
  echo "Make sure you are authenticated. Usage:"
  echo "  AWS_PROFILE=marketplace $0 ${AMI_ID}"
  exit 1
}

ACCOUNT_ID=$(echo "${CALLER_IDENTITY}" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)

if [ "${ACCOUNT_ID}" != "${EXPECTED_ACCOUNT}" ]; then
  echo "ERROR: Wrong AWS account."
  echo "  Expected: ${EXPECTED_ACCOUNT} (neo4j-marketplace)"
  echo "  Got:      ${ACCOUNT_ID}"
  exit 1
fi

echo "  Account: ${ACCOUNT_ID} (neo4j-marketplace)"
echo "  AMI:     ${AMI_ID}"
echo "  Region:  ${REGION}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Verify the AMI exists
# ---------------------------------------------------------------------------
echo "Verifying AMI ${AMI_ID} exists..."
AMI_STATE=$(aws ec2 describe-images \
  --region "${REGION}" \
  --image-ids "${AMI_ID}" \
  --query "Images[0].State" \
  --output text 2>/dev/null || true)

if [ -z "${AMI_STATE}" ] || [ "${AMI_STATE}" == "None" ]; then
  echo "ERROR: AMI ${AMI_ID} not found in ${REGION}."
  exit 1
fi

if [ "${AMI_STATE}" != "available" ]; then
  echo "ERROR: AMI ${AMI_ID} is in state '${AMI_STATE}' (expected 'available')."
  exit 1
fi
echo "AMI is available."

# ---------------------------------------------------------------------------
# Step 2: Create a temporary IAM role with SSM permissions
#
# The test instance needs the AmazonSSMManagedInstanceCore managed policy
# so the SSM agent can register and receive Run Command invocations.
# ---------------------------------------------------------------------------
ROLE_NAME="neo4j-ce-ami-test-ssm-role"
PROFILE_NAME="neo4j-ce-ami-test-ssm-profile"

echo ""
echo "Setting up IAM role for SSM access..."

# Create role (idempotent — ignore AlreadyExists)
aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' \
  --tags Key=Purpose,Value=marketplace-ami-test \
  2>/dev/null || true

aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
  2>/dev/null || true

# Create instance profile and add role (idempotent)
aws iam create-instance-profile \
  --instance-profile-name "${PROFILE_NAME}" \
  2>/dev/null || true

aws iam add-role-to-instance-profile \
  --instance-profile-name "${PROFILE_NAME}" \
  --role-name "${ROLE_NAME}" \
  2>/dev/null || true

# IAM is eventually consistent — the instance profile may not be usable
# immediately after creation. A brief pause avoids launch failures.
echo "Waiting for IAM propagation..."
sleep 10

# ---------------------------------------------------------------------------
# Step 3: Launch test instance
# ---------------------------------------------------------------------------
echo ""
echo "Launching test instance from ${AMI_ID}..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "${REGION}" \
  --image-id "${AMI_ID}" \
  --instance-type "${INSTANCE_TYPE}" \
  --iam-instance-profile "Name=${PROFILE_NAME}" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications "${INSTANCE_TAGS}" \
  --query "Instances[0].InstanceId" \
  --output text)

if [ -z "${INSTANCE_ID}" ]; then
  echo "ERROR: Failed to launch test instance."
  exit 1
fi
echo "Instance launched: ${INSTANCE_ID}"

# ---------------------------------------------------------------------------
# Cleanup trap — always terminate the test instance on exit
# ---------------------------------------------------------------------------
cleanup() {
  echo ""
  echo "Cleaning up: terminating test instance ${INSTANCE_ID}..."
  aws ec2 terminate-instances \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 4: Wait for instance to be running and SSM agent to register
# ---------------------------------------------------------------------------
echo ""
echo "Waiting for instance to start..."
aws ec2 wait instance-running \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}"
echo "Instance running."

echo "Waiting for SSM agent to register (may take 30-60 seconds)..."
SSM_READY=false
for i in $(seq 1 30); do
  SSM_STATUS=$(aws ssm describe-instance-information \
    --region "${REGION}" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null || true)

  if [ "${SSM_STATUS}" == "Online" ]; then
    SSM_READY=true
    break
  fi
  sleep 5
done

if [ "${SSM_READY}" != "true" ]; then
  echo "ERROR: SSM agent did not register within 150 seconds."
  echo "The instance may not have internet access or the IAM role may not have propagated."
  exit 1
fi
echo "SSM agent online."

# ---------------------------------------------------------------------------
# Step 5: Run verification commands via SSM Run Command
#
# The AMI is a base OS image only. We verify:
#   - SSH password authentication is disabled
#   - Root login is restricted
#   - OS is Amazon Linux 2023
# ---------------------------------------------------------------------------
echo ""
echo "Running verification commands..."

# Send the verification commands as a single script
COMMAND_ID=$(aws ssm send-command \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --comment "Neo4j CE base AMI verification" \
  --parameters 'commands=[
    "echo \"=== CHECK 1: SSH password authentication ===\"",
    "grep -i PasswordAuthentication /etc/ssh/sshd_config | head -5",
    "echo \"\"",
    "echo \"=== CHECK 2: Root login disabled ===\"",
    "grep -i PermitRootLogin /etc/ssh/sshd_config | head -5",
    "echo \"\"",
    "echo \"=== CHECK 3: OS identity ===\"",
    "cat /etc/os-release 2>&1 | head -5 || echo FAIL: cannot read os-release"
  ]' \
  --query "Command.CommandId" \
  --output text)

echo "Command sent: ${COMMAND_ID}"
echo "Waiting for results..."

# Poll for command completion
CMD_STATUS="InProgress"
for i in $(seq 1 30); do
  CMD_STATUS=$(aws ssm list-commands \
    --region "${REGION}" \
    --command-id "${COMMAND_ID}" \
    --query "Commands[0].Status" \
    --output text 2>/dev/null || true)

  if [ "${CMD_STATUS}" == "Success" ] || [ "${CMD_STATUS}" == "Failed" ]; then
    break
  fi
  sleep 5
done

# ---------------------------------------------------------------------------
# Step 6: Retrieve and display results
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  AMI Verification Results"
echo "============================================="
echo ""

COMMAND_OUTPUT=$(aws ssm get-command-invocation \
  --region "${REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query "StandardOutputContent" \
  --output text 2>/dev/null || true)

COMMAND_ERROR=$(aws ssm get-command-invocation \
  --region "${REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query "StandardErrorContent" \
  --output text 2>/dev/null || true)

echo "${COMMAND_OUTPUT}"

if [ -n "${COMMAND_ERROR}" ] && [ "${COMMAND_ERROR}" != "None" ]; then
  echo ""
  echo "--- stderr ---"
  echo "${COMMAND_ERROR}"
fi

# ---------------------------------------------------------------------------
# Step 7: Evaluate pass/fail
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
FAILURES=0

# Check SSH password auth disabled (match explicit uncommented setting)
if echo "${COMMAND_OUTPUT}" | grep -q "^PasswordAuthentication no"; then
  echo "  PASS: SSH password authentication is disabled"
else
  echo "  FAIL: SSH password authentication may not be disabled"
  FAILURES=$((FAILURES + 1))
fi

# Check root login restricted (match explicit uncommented setting).
# "prohibit-password" is the modern name; "without-password" is the deprecated alias.
if echo "${COMMAND_OUTPUT}" | grep -qE "^PermitRootLogin (prohibit-password|without-password)"; then
  echo "  PASS: Root login is restricted"
else
  echo "  FAIL: Root login may not be properly restricted"
  FAILURES=$((FAILURES + 1))
fi

# Check OS identity (NAME and VERSION are on separate lines in os-release)
if echo "${COMMAND_OUTPUT}" | grep -q 'VERSION_ID="2023"'; then
  echo "  PASS: OS is Amazon Linux 2023"
else
  echo "  FAIL: OS does not appear to be Amazon Linux 2023"
  FAILURES=$((FAILURES + 1))
fi

echo "============================================="
echo ""

if [ "${FAILURES}" -gt 0 ]; then
  echo "  RESULT: ${FAILURES} check(s) FAILED"
  echo ""
  echo "  Review the output above and fix the AMI build."
  # Instance is terminated by the cleanup trap
  exit 1
else
  echo "  RESULT: All checks PASSED"
  echo ""
  echo "  AMI ${AMI_ID} is ready for Marketplace scanning."
  echo "  Next: Submit via Marketplace Portal > Test 'Add version'"
fi
echo "============================================="
# Instance is terminated by the cleanup trap
