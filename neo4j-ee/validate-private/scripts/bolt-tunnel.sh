#!/usr/bin/env bash
# bolt-tunnel.sh — Open an SSM port-forward tunnel to Neo4j Bolt (port 7687)
#
# Required when using Neo4j Browser alongside browser-tunnel.sh (port 7473).
# Not needed for admin-shell, run-cypher, or validate-private — those run on
# the bastion and connect to the NLB directly.
#
# After the tunnel opens, map AdvertisedDNS to 127.0.0.1 in your laptop's
# /etc/hosts, then connect with: neo4j+s://<AdvertisedDNS>:7687
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
ADVERTISED_DNS=$(read_field "$OUTPUTS_FILE" "AdvertisedDNS")

echo "=== Neo4j Bolt Tunnel ==="
echo ""
echo "  Stack:   ${STACK_NAME}"
echo "  Region:  ${REGION}"
echo "  Bastion: ${BASTION_ID}"
echo ""
echo "  AdvertisedDNS: ${ADVERTISED_DNS}"
echo ""
echo "  Tunnel:  localhost:7687  ->  ${NLB_DNS}:7687"
echo ""
echo "  Add to your laptop's /etc/hosts so the ACM cert SAN validates:"
echo "    127.0.0.1 ${ADVERTISED_DNS}"
echo ""
echo "  Connect with: neo4j+s://${ADVERTISED_DNS}:7687"
echo "  (Run browser-tunnel.sh in a second terminal for Neo4j Browser access)"
echo ""
echo "  Press Ctrl-C to close."
echo ""

exec aws ssm start-session \
  --target "${BASTION_ID}" \
  --region "${REGION}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${NLB_DNS},portNumber=7687,localPortNumber=7687"
