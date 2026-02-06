#!/bin/bash
# test-stack.sh — Verify a deployed Neo4j CE CloudFormation stack
#
# Connects to the NLB endpoint and validates HTTP, Bolt, authentication,
# Cypher execution, and (optionally) APOC availability.
#
# Prerequisites:
#   - cypher-shell installed locally (for Bolt tests)
#   - stack-outputs.txt (written by deploy.sh)
#
# Usage:
#   ./test-stack.sh [--password <password>]
#
# If --password is omitted, reads the password from stack-outputs.txt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUTS_FILE="${SCRIPT_DIR}/stack-outputs.txt"

# Readiness polling configuration
READY_TIMEOUT=300    # seconds — total time to wait for NLB + Neo4j
READY_INTERVAL=10    # seconds — time between polling attempts

# ---------------------------------------------------------------------------
# Helper: read a value from a "Key = Value" file
# ---------------------------------------------------------------------------
read_field() {
  local file="$1"
  local key="$2"
  grep "^${key}" "$file" | sed 's/^[^=]*= *//' | tr -d '\r'
}

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------
PASSWORD_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --password)
      PASSWORD_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--password <password>]" >&2
      exit 1
      ;;
  esac
done

echo "=== Neo4j CE Stack Tester ==="
echo ""

# ---------------------------------------------------------------------------
# Preflight: Verify cypher-shell is installed
# ---------------------------------------------------------------------------
echo "Checking for cypher-shell..."
if ! command -v cypher-shell &> /dev/null; then
  echo ""
  echo "ERROR: cypher-shell is not installed."
  echo ""
  echo "cypher-shell is required for Bolt connectivity tests."
  echo ""
  echo "Install options:"
  echo "  macOS (Homebrew):"
  echo "    brew install cypher-shell"
  echo ""
  echo "  Linux (Debian/Ubuntu):"
  echo "    wget -O - https://debian.neo4j.com/neotechnology.gpg.key | sudo apt-key add -"
  echo "    echo 'deb https://debian.neo4j.com stable latest' | sudo tee /etc/apt/sources.list.d/neo4j.list"
  echo "    sudo apt-get update && sudo apt-get install -y cypher-shell"
  echo ""
  echo "  Linux (RHEL/Amazon Linux):"
  echo "    sudo rpm --import https://debian.neo4j.com/neotechnology.gpg.key"
  echo "    sudo dnf install -y cypher-shell"
  echo ""
  echo "  Direct download:"
  echo "    https://neo4j.com/deployment-center/"
  exit 1
fi
echo "  cypher-shell found: $(command -v cypher-shell)"

# ---------------------------------------------------------------------------
# Load configuration from deploy.sh output files
# ---------------------------------------------------------------------------
echo ""
echo "Loading stack configuration..."

if [ ! -f "${OUTPUTS_FILE}" ]; then
  echo "ERROR: ${OUTPUTS_FILE} not found." >&2
  echo "Run deploy.sh first to create a stack." >&2
  exit 1
fi

BROWSER_URL=$(read_field "${OUTPUTS_FILE}" "Neo4jBrowserURL")
NEO4J_URI=$(read_field "${OUTPUTS_FILE}" "Neo4jURI")
USERNAME=$(read_field "${OUTPUTS_FILE}" "Username")
STACK_NAME=$(read_field "${OUTPUTS_FILE}" "StackName")
REGION=$(read_field "${OUTPUTS_FILE}" "Region")
INSTALL_APOC=$(read_field "${OUTPUTS_FILE}" "InstallAPOC")

if [ -n "${PASSWORD_OVERRIDE}" ]; then
  PASSWORD="${PASSWORD_OVERRIDE}"
else
  PASSWORD=$(read_field "${OUTPUTS_FILE}" "Password")
fi

# Extract the NLB hostname from the browser URL (strip http:// and :7474)
NLB_HOST=$(echo "${BROWSER_URL}" | sed 's|http://||' | sed 's|:7474||')
HTTP_ENDPOINT="${BROWSER_URL}"
BOLT_ENDPOINT="${NEO4J_URI}"

echo "  Stack:        ${STACK_NAME}"
echo "  Region:       ${REGION}"
echo "  NLB:          ${NLB_HOST}"
echo "  HTTP:         ${HTTP_ENDPOINT}"
echo "  Bolt:         ${BOLT_ENDPOINT}"
echo "  Username:     ${USERNAME}"
echo "  InstallAPOC:  ${INSTALL_APOC}"
echo ""

# ---------------------------------------------------------------------------
# Wait for NLB + Neo4j to become reachable
# ---------------------------------------------------------------------------
echo "Waiting for Neo4j to become reachable (timeout: ${READY_TIMEOUT}s)..."

ELAPSED=0
while [ "${ELAPSED}" -lt "${READY_TIMEOUT}" ]; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 \
    "${HTTP_ENDPOINT}" 2>/dev/null || true)

  if [ "${HTTP_CODE}" = "200" ]; then
    echo "  Neo4j HTTP endpoint is responding (${ELAPSED}s elapsed)."
    break
  fi

  echo "  Not ready yet (HTTP ${HTTP_CODE:-timeout})... retrying in ${READY_INTERVAL}s"
  sleep "${READY_INTERVAL}"
  ELAPSED=$((ELAPSED + READY_INTERVAL))
done

if [ "${ELAPSED}" -ge "${READY_TIMEOUT}" ]; then
  echo ""
  echo "ERROR: Neo4j did not become reachable within ${READY_TIMEOUT}s."
  echo ""
  echo "Troubleshooting:"
  echo "  - Check stack status:"
  echo "      aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${REGION}"
  echo "  - Check instance logs via the EC2 console or:"
  echo "      aws ec2 get-console-output --instance-id <id> --region ${REGION}"
  exit 1
fi

echo ""

# ---------------------------------------------------------------------------
# Test execution helpers
# ---------------------------------------------------------------------------
FAILURES=0
TESTS_RUN=0

run_test() {
  local test_name="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "--- Test ${TESTS_RUN}: ${test_name} ---"
}

pass() {
  echo "  PASS: $1"
  echo ""
}

fail() {
  echo "  FAIL: $1"
  echo ""
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# Test 1: HTTP API — Discovery endpoint returns neo4j_version
# ---------------------------------------------------------------------------
run_test "HTTP API"

HTTP_RESPONSE=$(curl -s --max-time 10 "${HTTP_ENDPOINT}" 2>/dev/null || true)

if [ -z "${HTTP_RESPONSE}" ]; then
  fail "HTTP endpoint returned empty response"
else
  if echo "${HTTP_RESPONSE}" | grep -q "neo4j_version"; then
    NEO4J_VERSION=$(echo "${HTTP_RESPONSE}" | grep -o '"neo4j_version":"[^"]*"' | cut -d'"' -f4)
    pass "HTTP endpoint returned neo4j_version: ${NEO4J_VERSION}"
  else
    fail "HTTP response does not contain neo4j_version. Response: ${HTTP_RESPONSE}"
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: Authentication — POST with Basic Auth
# ---------------------------------------------------------------------------
run_test "Authentication (HTTP)"

AUTH_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  -u "${USERNAME}:${PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{"statements":[{"statement":"RETURN 1"}]}' \
  "${HTTP_ENDPOINT}/db/neo4j/tx/commit" 2>/dev/null || true)

if [ "${AUTH_HTTP_CODE}" = "200" ]; then
  pass "Authentication successful (HTTP 200)"
elif [ "${AUTH_HTTP_CODE}" = "401" ]; then
  fail "Authentication failed (HTTP 401). Check the password."
else
  fail "Unexpected HTTP status: ${AUTH_HTTP_CODE}"
fi

# ---------------------------------------------------------------------------
# Test 3: Bolt + Cypher — cypher-shell connects and runs a query
# ---------------------------------------------------------------------------
run_test "Bolt connectivity (cypher-shell)"

BOLT_EXIT=0
BOLT_RESULT=$(cypher-shell \
  -a "${BOLT_ENDPOINT}" \
  -u "${USERNAME}" \
  -p "${PASSWORD}" \
  --format plain \
  "RETURN 1 AS result" 2>&1) || BOLT_EXIT=$?

if [ "${BOLT_EXIT}" -eq 0 ]; then
  if echo "${BOLT_RESULT}" | grep -q "1"; then
    pass "Bolt connected, Cypher returned: $(echo "${BOLT_RESULT}" | tail -1)"
  else
    fail "Bolt connected but unexpected result: ${BOLT_RESULT}"
  fi
else
  fail "cypher-shell failed (exit ${BOLT_EXIT}): ${BOLT_RESULT}"
fi

# ---------------------------------------------------------------------------
# Test 4: APOC — Verify apoc.version() is callable (if installed)
# ---------------------------------------------------------------------------
if [ "${INSTALL_APOC}" = "yes" ]; then
  run_test "APOC plugin"

  APOC_EXIT=0
  APOC_RESULT=$(cypher-shell \
    -a "${BOLT_ENDPOINT}" \
    -u "${USERNAME}" \
    -p "${PASSWORD}" \
    --format plain \
    "RETURN apoc.version() AS version" 2>&1) || APOC_EXIT=$?

  if [ "${APOC_EXIT}" -eq 0 ]; then
    APOC_VERSION=$(echo "${APOC_RESULT}" | tail -1 | tr -d '"' | xargs)
    pass "APOC is available, version: ${APOC_VERSION}"
  else
    fail "APOC query failed (exit ${APOC_EXIT}): ${APOC_RESULT}"
  fi
else
  echo "--- Skipping APOC test (InstallAPOC=${INSTALL_APOC}) ---"
  echo ""
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo "============================================="
echo "  Stack Test Results"
echo "============================================="
echo ""
echo "  Stack:     ${STACK_NAME}"
echo "  Endpoint:  ${NLB_HOST}"
echo ""

if [ "${FAILURES}" -gt 0 ]; then
  echo "  RESULT: ${FAILURES} of ${TESTS_RUN} test(s) FAILED"
  echo ""
  echo "  Review the output above for details."
  echo "============================================="
  exit 1
else
  echo "  RESULT: All ${TESTS_RUN} tests PASSED"
  echo ""
  echo "  The Neo4j CE stack is functional."
  echo "============================================="
  exit 0
fi
