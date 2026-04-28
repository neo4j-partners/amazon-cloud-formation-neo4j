#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK="test-ee-1777345221"
DELAY=3600

echo "[$(date)] Sleeping ${DELAY}s before tearing down ${STACK}..."
sleep "${DELAY}"
echo "[$(date)] Starting teardown of ${STACK}..."
"${SCRIPT_DIR}/teardown.sh" "${STACK}"
echo "[$(date)] Done."
