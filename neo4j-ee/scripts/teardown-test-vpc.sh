#!/usr/bin/env bash
# teardown-test-vpc.sh — Delete a test VPC created by create-test-vpc.sh.
#
# Reads .deploy/vpc-<ts>.txt and deletes all resources in reverse creation order.
#
# Usage:
#   scripts/teardown-test-vpc.sh [vpc-<ts>]
#
# If the argument is omitted, uses the most recently modified vpc-*.txt in .deploy/.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/../.deploy"

VPC_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -*) echo "ERROR: Unknown option '$1'" >&2; exit 1 ;;
        *)  VPC_ARG="$1"; shift ;;
    esac
done

read_field() {
    local file="$1" key="$2"
    grep "^${key}" "$file" | sed 's/^[^=]*= *//' | tr -d '\r'
}

if [[ -n "$VPC_ARG" ]]; then
    OUTPUTS_FILE="${DEPLOY_DIR}/${VPC_ARG}.txt"
else
    OUTPUTS_FILE=$(ls -t "${DEPLOY_DIR}"/vpc-*.txt 2>/dev/null | head -1 || true)
fi

if [[ -z "$OUTPUTS_FILE" || ! -f "$OUTPUTS_FILE" ]]; then
    echo "ERROR: No VPC deployment found." >&2
    if [[ -n "$VPC_ARG" ]]; then
        echo "File not found: ${DEPLOY_DIR}/${VPC_ARG}.txt" >&2
    else
        echo "No vpc-*.txt files in ${DEPLOY_DIR}/" >&2
    fi
    exit 1
fi

VPC_ID=$(read_field "$OUTPUTS_FILE" "VpcId")
REGION=$(read_field "$OUTPUTS_FILE" "Region")
WITH_ENDPOINTS=$(read_field "$OUTPUTS_FILE" "WithEndpoints")
NAT_1=$(read_field "$OUTPUTS_FILE" "NatGateway1Id")
NAT_2=$(read_field "$OUTPUTS_FILE" "NatGateway2Id")
NAT_3=$(read_field "$OUTPUTS_FILE" "NatGateway3Id")
EIP_1=$(read_field "$OUTPUTS_FILE" "Eip1AllocationId")
EIP_2=$(read_field "$OUTPUTS_FILE" "Eip2AllocationId")
EIP_3=$(read_field "$OUTPUTS_FILE" "Eip3AllocationId")
SUBNET_1=$(read_field "$OUTPUTS_FILE" "Subnet1Id")
SUBNET_2=$(read_field "$OUTPUTS_FILE" "Subnet2Id")
SUBNET_3=$(read_field "$OUTPUTS_FILE" "Subnet3Id")
PUB_SUBNET_1=$(read_field "$OUTPUTS_FILE" "PublicSubnet1Id")
PUB_SUBNET_2=$(read_field "$OUTPUTS_FILE" "PublicSubnet2Id")
PUB_SUBNET_3=$(read_field "$OUTPUTS_FILE" "PublicSubnet3Id")
RT_1=$(read_field "$OUTPUTS_FILE" "RouteTable1Id")
RT_2=$(read_field "$OUTPUTS_FILE" "RouteTable2Id")
RT_3=$(read_field "$OUTPUTS_FILE" "RouteTable3Id")
IGW_ID=$(read_field "$OUTPUTS_FILE" "IgwId")

echo "=== Test VPC Teardown ==="
echo ""
echo "  VPC:    $VPC_ID"
echo "  Region: $REGION"
echo ""

# Step 1: Interface endpoints (if created)
if [[ "$WITH_ENDPOINTS" == "true" ]]; then
    echo "Deleting VPC interface endpoints..."
    ENDPOINT_IDS=$(aws ec2 describe-vpc-endpoints \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
                  "Name=vpc-endpoint-state,Values=available,pending" \
        --query 'VpcEndpoints[].VpcEndpointId' \
        --output text || true)
    if [[ -n "$ENDPOINT_IDS" ]]; then
        # shellcheck disable=SC2086
        aws ec2 delete-vpc-endpoints --region "$REGION" \
            --vpc-endpoint-ids $ENDPOINT_IDS > /dev/null
        echo "  Waiting for endpoints to delete..."
        for i in $(seq 1 30); do
            remaining=$(aws ec2 describe-vpc-endpoints \
                --region "$REGION" \
                --filters "Name=vpc-id,Values=${VPC_ID}" \
                          "Name=vpc-endpoint-state,Values=deleting,available,pending" \
                --query 'length(VpcEndpoints)' --output text)
            if [[ "$remaining" == "0" ]]; then
                break
            fi
            echo "  Still deleting ($remaining remaining)..."
            sleep 10
        done
    fi
    echo "  Endpoints deleted."
fi

# Step 2: NAT gateways
echo "Deleting NAT gateways..."
for nat in "$NAT_1" "$NAT_2" "$NAT_3"; do
    aws ec2 delete-nat-gateway --region "$REGION" \
        --nat-gateway-id "$nat" > /dev/null || true
done
echo "  Waiting for NAT gateways to delete (60-90s)..."
for i in $(seq 1 30); do
    pending=$(aws ec2 describe-nat-gateways \
        --region "$REGION" \
        --filter "Name=nat-gateway-id,Values=${NAT_1},${NAT_2},${NAT_3}" \
        --query "NatGateways[?State!='deleted'].NatGatewayId" \
        --output text || true)
    if [[ -z "$pending" ]]; then
        break
    fi
    echo "  Still deleting... ($pending)"
    sleep 10
done
echo "  NAT gateways deleted."

# Step 3: Release EIPs
echo "Releasing EIPs..."
for eip in "$EIP_1" "$EIP_2" "$EIP_3"; do
    aws ec2 release-address --region "$REGION" \
        --allocation-id "$eip" 2>/dev/null || true
done
echo "  EIPs released."

# Step 4: Delete all subnets (implicitly removes route table associations)
echo "Deleting subnets..."
for subnet in "$SUBNET_1" "$SUBNET_2" "$SUBNET_3" \
              "$PUB_SUBNET_1" "$PUB_SUBNET_2" "$PUB_SUBNET_3"; do
    aws ec2 delete-subnet --region "$REGION" \
        --subnet-id "$subnet" 2>/dev/null || true
done
echo "  Subnets deleted."

# Step 5: Delete private route tables (main RT is deleted with the VPC)
echo "Deleting private route tables..."
for rt in "$RT_1" "$RT_2" "$RT_3"; do
    aws ec2 delete-route-table --region "$REGION" \
        --route-table-id "$rt" 2>/dev/null || true
done
echo "  Route tables deleted."

# Step 6: Detach and delete IGW
echo "Detaching and deleting internet gateway..."
aws ec2 detach-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
aws ec2 delete-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" 2>/dev/null || true
echo "  IGW deleted."

# Step 7: Delete VPC
echo "Deleting VPC..."
aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
echo "  VPC deleted."

# Step 8: Remove output file
rm -f "$OUTPUTS_FILE"

echo ""
echo "============================================="
echo "  VPC teardown complete."
echo "============================================="
