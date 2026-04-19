#!/usr/bin/env bash
# browser-tunnel.sh — Open an SSM port-forward tunnel to the Neo4j Browser (port 7474)
#
# After the tunnel opens, go to http://localhost:7474 in your browser.
# Use bolt://localhost:7687 for Bolt connections from the same laptop session.
#
# Note: writes through Neo4j Browser go to whichever cluster node the NLB picks,
# which may or may not be the leader. For guaranteed-leader writes, use:
#   uv run admin-shell
#
# Usage: ./scripts/browser-tunnel.sh [stack-name]
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

echo "=== Neo4j Browser Tunnel ==="
echo ""
echo "  Stack:   ${STACK_NAME}"
echo "  Region:  ${REGION}"
echo "  Bastion: ${BASTION_ID}"
echo ""
echo "  Tunnel:  localhost:7474  ->  ${NLB_DNS}:7474"
echo ""
echo "  Once the tunnel opens:"
echo "    Browser: http://localhost:7474"
echo "    Bolt:    bolt://localhost:7687  (if Bolt tunnel is also open)"
echo ""
echo "  Press Ctrl-C to close."
echo ""

exec aws ssm start-session \
  --target "${BASTION_ID}" \
  --region "${REGION}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${NLB_DNS},portNumber=7474,localPortNumber=7474"
