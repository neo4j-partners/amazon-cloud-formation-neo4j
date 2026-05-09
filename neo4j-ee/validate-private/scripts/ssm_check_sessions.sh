#!/usr/bin/env bash
# Backward-compatible wrapper for the uv Python CLI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."
exec uv run ssm-check-sessions "$@"
