#!/usr/bin/env bash
# bolt-tunnel.sh — Open an SSM port-forward tunnel to Neo4j Bolt (port 7687)
#
# Required when using Neo4j Browser alongside browser-tunnel.sh (port 7474).
# Not needed for admin-shell, run-cypher, or validate-private — those run on
# the bastion and connect to the NLB directly.
#
# After the tunnel opens, connect with: bolt://localhost:7687
#
# Usage: ./scripts/bolt-tunnel.sh [stack-name]
# Prerequisite: AWS Session Manager Plugin (brew install --cask session-manager-plugin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

OUTPUTS_FILE=$(resolve_stack "${1:-}")
require_private_mode "$OUTPUTS_FILE"

STACK_NAME=$(read_field "$OUTPUTS_FILE" "StackName")
REGION=$(read_field "$OUTPUTS_FILE" "Region")
BASTION_ID=$(read_field "$OUTPUTS_FILE" "Neo4jOperatorBastionId")
NLB_DNS=$(read_field "$OUTPUTS_FILE" "Neo4jInternalDNS")

echo "=== Neo4j Bolt Tunnel ==="
echo ""
echo "  Stack:   ${STACK_NAME}"
echo "  Region:  ${REGION}"
echo "  Bastion: ${BASTION_ID}"
echo ""
echo "  Tunnel:  localhost:7687  ->  ${NLB_DNS}:7687"
echo ""
echo "  Connect with: bolt://localhost:7687"
echo "  (Run browser-tunnel.sh in a second terminal for Neo4j Browser access)"
echo ""
echo "  Press Ctrl-C to close."
echo ""

exec aws ssm start-session \
  --target "${BASTION_ID}" \
  --region "${REGION}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${NLB_DNS},portNumber=7687,localPortNumber=7687"
