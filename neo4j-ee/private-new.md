# Automated Test Plan: Private — New VPC Template

End-to-end plan for deploying and validating `templates/neo4j-private.template.yaml` (the "Private — New VPC" Marketplace listing) without manual intervention.

---

## Configuration

Defaults used throughout this plan. Adjust at the top before running.

| Variable | Default | Notes |
|---|---|---|
| `REGION` | `us-east-1` | Pinned to source region — avoids 10-20 min AMI copy |
| `SERVERS` | `3` | 3-node required by the failover and resilience suites |
| `INSTANCE_FAMILY` | `t3` | `t3.medium`; swap to `r8i` for memory-optimized |
| `TLS` | off | Add `--tls` to deploy if Bolt TLS path needs coverage |
| `DELETE_VOLUMES` | yes | Automated test; retain only for post-mortem inspection |

---

## What "Private — New VPC" Creates

Unlike `ExistingVpc` (which takes pre-existing subnet IDs), this template owns all networking. The test plan specifically exercises that stack-created infrastructure:

- VPC + 3 public subnets (NAT Gateways) + 3 private subnets (Neo4j instances)
- Internal NLB across the private subnets
- VPC interface endpoints: `ssm`, `ssmmessages`, `logs`, `secretsmanager`
- Operator bastion (`t4g.nano`) in a private subnet — not an NLB target
- SSM contract parameters under `/neo4j-ee/<stack>/`
- 3-node Neo4j Raft cluster

---

## Prerequisites

```bash
# 1. AMI must exist
cat neo4j-ee/marketplace/ami-id.txt        # must print a valid ami-* ID
# If missing: AWS_PROFILE=marketplace ./marketplace/create-ami.sh

# 2. AWS credentials
aws sts get-caller-identity --profile default

# 3. Session Manager Plugin (operator bastion access)
session-manager-plugin --version

# 4. uv (Python tooling for validate-private)
uv --version
```

---

## Phase 1: Deploy (5–10 min) ✅ DONE — `test-ee-1777182827`

```bash
cd neo4j-ee
./deploy.py --mode Private --number-of-servers 3 --region us-east-1
```

**Writes**: `.deploy/<stack-name>.txt` with stack outputs (NLB DNS, bastion ID, password, SSM paths).

**Pass criteria**: CloudFormation reaches `CREATE_COMPLETE`. The deploy script waits for the waiter and exits 0.

**Failure**: If the stack hits `CREATE_FAILED`, check `/var/log/cloud-init-output.log` on any node via SSM send-command (bastion may not be up yet — use a node instance ID from the ASG).

---

## Phase 2: Preflight (45–75 s) ✅ DONE — 11/11 passed

```bash
cd neo4j-ee/validate-private
./scripts/preflight.sh <stack-name>
```

Runs 11 required checks + 1 informational:

1. CloudFormation stack status = `CREATE_COMPLETE` or `UPDATE_COMPLETE`
2. Bastion SSM PingStatus = Online
3. Neo4j Python driver installed on bastion
4. `cypher-shell` installed on bastion
5. Secret `neo4j/<stack>/password` exists in Secrets Manager
6. Contract SSM params: `vpc-id`, `nlb-dns`, `external-sg-id`, `password-secret-arn`, `vpc-endpoint-sg-id`
7. *(informational)* Operational SSM params: `region`, `stack-name`, `private-subnet-1-id`, `private-subnet-2-id`
8. VPC interface endpoints in state `available`: secretsmanager, logs, ssm, ssmmessages
9–12. Each endpoint reachable via curl from the bastion (expects HTTP 400/403/404 — unsigned request rejected by PrivateLink, not timed out)

**Pass criteria**: `FAIL_COUNT=0`. Exit 0.

**Failure**: Bastion not ready within 2-3 min of stack completion is the most common early failure — retry once. Endpoint reachability failures indicate a security group misconfiguration on the VPC endpoint or endpoint SG.

---

## Phase 3: Basic Checks (25–35 s) ✅ DONE — 6/6 passed

```bash
cd neo4j-ee/validate-private
uv run validate-private --stack <stack-name>
```

Runs 7 checks via the operator bastion:

1. **Bolt connectivity** — `RETURN 1 AS result` through NLB
2. **Server status** — `dbms.components()` returns `edition = enterprise`
3. **Listen address** — `server.default_listen_address = 0.0.0.0`
4. **Memory configuration** — heap + pagecache settings present
5. **Data directory** — `/var/lib/neo4j/data`
6. **APOC** — skipped unless `InstallAPOC=yes` in the outputs file
7. **Cluster roles** — `SHOW DATABASE neo4j YIELD serverID, writer` returns 3 rows, exactly 1 writer, all serverIDs distinct

`validate-private/config.py` gates on `DeploymentMode=Private` — it will refuse to run against a Public or ExistingVpc stack.

**Pass criteria**: All checks `PASS`. Exit 0.

---

## Phase 3.5: Deploy Sample Private App (background, ~3–5 min) ⏳ NEXT — blocked by bug in deploy-sample-private-app.sh

Start this immediately after Phase 3 exits — it runs while Phases 4 and 5 execute. The app stack typically finishes within 3–5 minutes, well before Phase 5.5 needs it.

```bash
# From neo4j-ee/sample-private-app/, in a second terminal or backgrounded
cd neo4j-ee/sample-private-app
./deploy-sample-private-app.sh "${STACK}" &
APP_DEPLOY_PID=$!
```

What this creates:
- Two Python 3.13 Lambdas in the cluster's private subnets, each behind an IAM-authenticated Function URL
- **Main Lambda** (`invoke.sh`) — connects via `neo4j://` on the internal NLB, writes a small fintech graph, returns a cluster health report
- **Resilience Lambda** (`validate.sh`) — picks a follower, stops `neo4j.service` via SSM, polls `SHOW SERVERS` until that member goes `Unavailable`, starts it, polls until it returns `Available`, reports timings
- A deploy S3 bucket (`neo4j-sample-private-app-deploy-<account>-<region>`) shared across runs but keyed by app stack name
- A local state file: `.deploy/sample-private-app-<ee-stack>.json` with the Function URLs

**Pass criteria**: `aws cloudformation deploy` exits 0. Function URL and Validate URL are present in the output JSON.

**Teardown ordering note**: The sample app owns two `SecurityGroupIngress` rules on the EE stack's security groups. It **must be torn down before the EE stack** (Phase 6). Deleting the EE stack first will stall at security group deletion.

---

## Phase 4: Failover Suite (~10–15 min)

```bash
uv run validate-private --stack <stack-name> --suite failover
```

Four sequential cases using `systemctl stop`/`start` via SSM (no instance termination):

| Case | What it does | Runtime |
|---|---|---|
| `follower-with-data` | Stop a follower, write data, restart, verify data visible | ~60 s |
| `leader` | Stop the leader, verify election, write on new leader | ~90 s |
| `rolling` | Stop each node in turn; cluster stays available throughout | ~4–15 min |
| `reads` | Stop two followers; verify reads still served by remaining nodes | ~90 s |

**Pass criteria**: All 4 cases report `PASS`. Exit 0.

---

## Phase 5: Resilience Suite (~20–25 min)

```bash
uv run validate-private --stack <stack-name> --suite resilience
```

Two cases that terminate EC2 instances and wait for ASG replacement:

| Case | What it does | Timeout |
|---|---|---|
| `single-loss` | Terminate 1 node; verify EBS reattach + sentinel data intact + quorum reforms | 900 s |
| `total-loss` | Terminate all 3 nodes simultaneously; verify all 3 volumes reattach + sentinel intact | 1200 s |

Each case writes a sentinel file to the data volume before termination and verifies it survives on the replacement instance — confirming `DeletionPolicy: Retain` and NVMe device resolution both work.

**Pass criteria**: Both cases `PASS`. Exit 0.

**Note**: The `--suite all` flag runs failover then resilience in sequence and skips resilience if failover had any failures.

---

## Phase 5.5: Sample App Tests (~2–3 min)

Wait for the background deploy from Phase 3.5 before running these.

```bash
# Wait for background deploy if still running
wait $APP_DEPLOY_PID

# Main Lambda: write a fintech graph, get cluster health report
cd neo4j-ee/sample-private-app
./invoke.sh

# Resilience Lambda: stop a follower via SSM, wait for recovery (~60-120s)
./validate.sh
```

**What `invoke.sh` checks**: edition=enterprise, Bolt connection to NLB, graph write succeeds, all 3 nodes appear in the routing table.

**What `validate.sh` checks**: `neo4j.service` can be stopped on a follower, `SHOW SERVERS` reflects the member going `Unavailable`, service restarts, member returns to `Available` — all within the resilience Lambda's 5-minute timeout (300 s). The main Lambda (`invoke.sh`) has a separate 30-second timeout; a timeout there indicates a connectivity or graph-write failure, not a recovery issue.

**Pass criteria**: Both scripts return JSON with no `error` key. Exit 0.

**Failure**: `validate.sh` timeout (>5 min) usually means the follower failed to recover — check the ASG activity and `/var/log/neo4j/debug.log` on the affected node via SSM. `invoke.sh` timeout (>30 s) indicates an NLB or Bolt connectivity issue — check the NLB target group health and Neo4j logs.

---

## Phase 6: Teardown (5–10 min)

```bash
# Sample app FIRST — it owns SG ingress rules on the EE stack
cd neo4j-ee/sample-private-app
./teardown-sample-private-app.sh "${STACK}"

# Then the EE stack
cd neo4j-ee
./teardown.sh --delete-volumes "${STACK}"
```

EE teardown deletes: CloudFormation stack, SSM parameter, password secret (force), Bolt TLS secret if present, retained EBS data volumes, `.deploy/<stack>.txt`.

Sample app teardown also purges all S3 versions of the Lambda zip under its scoped key.

**Pass criteria**: Both stacks reach `DELETE_COMPLETE`. Exit 0.

---

## Combined Run (one shot)

```bash
cd neo4j-ee

# Phase 1: Deploy EE stack
./deploy.py --mode Private --number-of-servers 3 --region us-east-1

# Capture stack name immediately — don't rely on ls -t after this point
STACK=$(ls -t .deploy/*.txt | head -1 | xargs basename | sed 's/\.txt$//')

# Kill background app deploy and print teardown reminder if the run exits early.
# Always runs on exit (success or failure) — harmless if APP_DEPLOY_PID is unset.
trap '
  if [[ -n "${APP_DEPLOY_PID:-}" ]]; then
    kill "${APP_DEPLOY_PID}" 2>/dev/null || true
    echo "Background app deploy killed."
    echo "If a partial sample-app stack exists, tear it down first:"
    echo "  cd neo4j-ee/sample-private-app && ./teardown-sample-private-app.sh ${STACK}"
    echo "  cd neo4j-ee && ./teardown.sh --delete-volumes ${STACK}"
  fi
' EXIT

# Phase 2: Preflight
cd validate-private
./scripts/preflight.sh "${STACK}"

# Phase 3: Basic checks
uv run validate-private --stack "${STACK}"

# Phase 3.5: Start sample app deploy in background
cd ../sample-private-app
./deploy-sample-private-app.sh "${STACK}" &
APP_DEPLOY_PID=$!

# Phase 4 + 5: Failover and resilience suites (while sample app deploys)
cd ../validate-private
uv run validate-private --stack "${STACK}" --suite all

# Phase 5.5: Sample app tests (wait for background deploy first)
wait $APP_DEPLOY_PID
cd ../sample-private-app
./invoke.sh
./validate.sh

# Phase 6: Teardown — sample app before EE stack
./teardown-sample-private-app.sh "${STACK}"
cd ..
./teardown.sh --delete-volumes "${STACK}"
```

Total wall-clock time: **40–60 min** (dominated by ASG replacement waits in Phase 5; sample app deploy overlaps with that window).

---

## Parallel Test Isolation

When running two or more full test runs simultaneously (e.g., `t3` vs `r8i`, or `1-node` vs `3-node`), the default stack selector (`ls -t .deploy/*.txt | head -1`) is unreliable — the wrong stack gets picked if two runs write files concurrently.

**Fix**: always capture `STACK` immediately after `deploy.py` exits and pass it explicitly to every subsequent command.

```bash
# Capture before any other deploy can write a newer file
STACK=$(ls -t .deploy/*.txt | head -1 | xargs basename | sed 's/\.txt$//')

# Pass explicitly — never rely on the default again
./scripts/preflight.sh "${STACK}"
uv run validate-private --stack "${STACK}"
uv run validate-private --stack "${STACK}" --suite all
./teardown.sh --delete-volumes "${STACK}"
```

All other resources are already isolated by stack name:

| Resource | Scoping |
|---|---|
| CloudFormation stacks | `test-ee-<timestamp>` — unique per run |
| SSM parameters | `/neo4j-ee/<stack>/` prefix |
| Secrets Manager | `neo4j/<stack>/password` |
| EBS volumes | Tagged with `StackID` |
| App stack | `neo4j-sample-private-app-<ee-stack>` |
| S3 Lambda key | `neo4j-sample-private-app-<ee-stack>/lambda.zip` |
| App JSON file | `.deploy/sample-private-app-<ee-stack>.json` |

The deploy S3 bucket (`neo4j-sample-private-app-deploy-<account>-<region>`) is shared but keys don't overlap. The AMI is read-only from `marketplace/ami-id.txt` — no write conflict.

---

## Failure Handling

| Failure point | Where to look | Action |
|---|---|---|
| Phase 1: stack stuck | `/var/log/cloud-init-output.log` (SSM send-command to node) | Check UserData; `teardown.sh` if unrecoverable |
| Phase 2: bastion not online | Wait 2-3 min; retry preflight | If still failing, inspect bastion UserData via SSM |
| Phase 3–5: Cypher failure | `validate-private` stdout + `/var/log/neo4j/debug.log` (SSM) | Leave stack up for inspection; teardown when done |
| Phase 3.5: app deploy fails | `aws cloudformation deploy` output | Check IAM permissions; run teardown-sample-private-app.sh then EE teardown |
| Phase 3.5: background deploy still running on failure | `ps` / `jobs` | Kill PID, check for partial app stack, then teardown-sample-private-app.sh before EE teardown (trap in combined run handles this automatically) |
| Phase 5: ASG timeout | ASG activity events in console | Extend `--timeout`; check `/var/log/cloud-init-output.log` on new instance |
| Phase 5.5: Lambda timeout | CloudWatch log group for the Lambda | Check Neo4j follower recovery via SSM on the affected node |

**Teardown order on failure**: always `teardown-sample-private-app.sh` first, then `teardown.sh --delete-volumes`. Reversing the order leaves orphaned SG ingress rules that stall EE stack deletion.

Leave stacks running for post-mortem. Once investigation is complete:

```bash
cd neo4j-ee/sample-private-app && ./teardown-sample-private-app.sh <stack>
cd neo4j-ee && ./teardown.sh --delete-volumes <stack>
```
