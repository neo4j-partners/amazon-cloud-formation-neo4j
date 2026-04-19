# neo4j-ee/scripts/

Operator scripts for EE Private-mode stacks. All scripts read AWS credentials from `AWS_PROFILE` (defaults to `default`). All accept an optional stack name as the first positional argument; if omitted, the most recently modified file in `.deploy/` is used.

For a full walkthrough of these scripts in context, see [`PRIVATE_ACCESS_GUIDE.md`](../PRIVATE_ACCESS_GUIDE.md).

| Script | What it does | Typical runtime |
|---|---|---|
| `get-password.sh [stack]` | Print the Neo4j password from Secrets Manager to stdout | <5s |
| `preflight.sh [stack]` | Run 6 prerequisite checks (stack status, bastion SSM, driver, cypher-shell, secret, SSM params). Exits 0 only if all pass. | 15–30s |
| `admin-shell.sh [stack]` | Open an interactive `cypher-shell` session on the bastion. Password is resolved on the bastion — not visible locally. | Interactive |
| `run-cypher.sh [stack] '<cypher>'` | Execute a Cypher query and print JSON rows to stdout. Cypher is the last positional argument. | 5–10s |
| `smoke-write.sh [stack] [N=20]` | Run N `CREATE ... DELETE` write operations through the cluster. Fails if any iteration fails. | ~60s at N=20 |
| `browser-tunnel.sh [stack]` | Open a port-forward tunnel to the NLB on port 7474. Go to `http://localhost:7474` after it opens. | Interactive |

Scripts that require Private-mode (`admin-shell.sh`, `run-cypher.sh`, `smoke-write.sh`, `browser-tunnel.sh`) exit with an error on Public stacks.

`common.sh` is sourced by all other scripts and is not intended to be executed directly.
