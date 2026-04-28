# validate-private

Operator tooling for Neo4j EE Private-mode stacks. All commands run from this directory (`neo4j-ee/validate-private/`).

For a full operator walkthrough, see [`../docs/PRIVATE.md`](../docs/PRIVATE.md).

---

## uv commands

These commands use the Neo4j Python driver and boto3 via SSM to reach the cluster through the operator bastion. Credentials are resolved on the bastion using its IAM role — they never appear on the operator's laptop or in CloudTrail.

| Command | What it does | Runtime |
|---|---|---|
| `uv run validate-private [--stack <name>]` | Run 8 validation checks: Bolt, server edition, listen address, memory config, data directory, APOC, GDS, cluster roles | 25–35s |
| `uv run run-cypher [stack] '<cypher>'` | Execute a Cypher query and print JSON rows to stdout | 5–10s |
| `uv run admin-shell [stack]` | Open an interactive `cypher-shell` session on the bastion | Interactive |

All commands default to the most recently modified file in `../.deploy/`. Pass a stack name to target a specific deployment.

---

## scripts/

Bash operator scripts that use the AWS CLI directly. All scripts read `AWS_PROFILE` from the environment (default: `default`). All accept an optional stack name as the first positional argument.

| Script | What it does | Runtime |
|---|---|---|
| `scripts/get-password.sh [stack]` | Print the Neo4j password from Secrets Manager to stdout | <5s |
| `scripts/preflight.sh [stack]` | Run 11 prerequisite checks (+ 1 informational): stack status, bastion SSM, Python driver, cypher-shell, secret, contract SSM params, VPC endpoints, and endpoint reachability probes. Exits 0 only if all required checks pass. | 45–75s |
| `scripts/smoke-write.sh [stack] [N=20]` | Run N `CREATE ... DELETE` write operations through the cluster. Fails if any iteration fails. | ~60s at N=20 |
| `scripts/browser-tunnel.sh [stack]` | Open a port-forward tunnel to the NLB on port 7474. Go to `http://localhost:7474` after it opens. | Interactive |
| `scripts/ssm_check_sessions.sh [stack] [region]` | List active SSM sessions for the stack's ASG instances. | <5s |
| `scripts/ssm_tunnel_test.py` | Diagnostic: test SSM port-forward tunnel flag combinations against the bastion. | Varies |

`scripts/common.sh` is sourced by the bash scripts and is not executed directly.

---

## Prerequisites

- **AWS CLI v2** and **Session Manager Plugin** (`brew install --cask session-manager-plugin`) for `admin-shell` and `browser-tunnel`
- **uv** for the Python commands (`brew install uv`)
- A deployed Private-mode stack with its output file in `../.deploy/`

Run `scripts/preflight.sh` first to confirm the stack and bastion are ready before using the other tools.
