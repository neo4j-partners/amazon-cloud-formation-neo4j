#!/usr/bin/env bash
# browser-tunnel.sh — Open an SSM port-forward tunnel to the Neo4j Browser (port 7473, HTTPS)
#
# After the tunnel opens, map AdvertisedDNS to 127.0.0.1 in /etc/hosts so the
# connection uses the certificate name, then go to https://<AdvertisedDNS>:7473.
# Use neo4j+s://<AdvertisedDNS>:7687 for trusted certs, or neo4j+ssc:// for
# self-signed test certs, from the same laptop session.
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
ADVERTISED_DNS=$(read_field "$OUTPUTS_FILE" "AdvertisedDNS")
SELF_SIGNED_CERTIFICATE=$(read_field "$OUTPUTS_FILE" "SelfSignedCertificate")
BOLT_SCHEME="neo4j+s"
if [ "${SELF_SIGNED_CERTIFICATE}" = "true" ]; then
  BOLT_SCHEME="neo4j+ssc"
fi

echo "=== Neo4j Browser Tunnel ==="
echo ""
echo "  Stack:         ${STACK_NAME}"
echo "  Region:        ${REGION}"
echo "  Bastion:       ${BASTION_ID}"
echo "  AdvertisedDNS: ${ADVERTISED_DNS}"
echo ""
echo "  Tunnel:  localhost:7473  ->  ${NLB_DNS}:7473  (HTTPS, NLB-terminated TLS)"
echo ""
echo "  Add to /etc/hosts so the connection uses the certificate name:"
echo "    127.0.0.1 ${ADVERTISED_DNS}"
echo ""
echo "  Once the tunnel opens:"
echo "    Browser: https://${ADVERTISED_DNS}:7473"
echo "    Bolt:    ${BOLT_SCHEME}://${ADVERTISED_DNS}:7687  (if Bolt tunnel is also open)"
echo ""
echo "  Press Ctrl-C to close."
echo ""

exec aws ssm start-session \
  --target "${BASTION_ID}" \
  --region "${REGION}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${NLB_DNS},portNumber=7473,localPortNumber=7473"
