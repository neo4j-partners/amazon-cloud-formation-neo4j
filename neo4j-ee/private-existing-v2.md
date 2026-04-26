# Automated Test Plan: Private — Existing VPC Template

End-to-end plan for deploying and validating `templates/neo4j-private-existing-vpc.template.yaml` (the "Private — Existing VPC" Marketplace listing) without manual intervention. All runs require a pre-created test VPC — see Phase 0.

---

## Test Matrix

| Path | Trigger | Servers | `CreateVpcEndpoints` | Focus |
|------|---------|---------|----------------------|-------|
| A — Fresh VPC | Every CI run (gate) | 3 | `true` | Template creates endpoints; full failover + resilience |
| B — Pre-existing endpoints | Weekly / pre-release | 1 | `false` | Template skips endpoint creation; SSM contract publishes the correct SG |

---

## Configuration

| Variable | Path A Default | Path B Default | Notes |
|---|---|---|---|
| `REGION` | `us-east-1` | `us-east-1` | Pinned to source region — avoids 10–20 min AMI copy |
| `SERVERS` | `3` | `1` | 3-node required by failover + resilience suites (Path A only) |
| `INSTANCE_FAMILY` | `t3` | `t3` | `t3.medium`; swap to `r8i` for memory-optimized |
| `TLS` | off | off | Add `--tls` to deploy if Bolt TLS path needs coverage |
| `DELETE_VOLUMES` | yes | yes | Automated test; retain only for post-mortem inspection |

---

## What ExistingVpc Adds vs Private

The ExistingVpc template is structurally identical to `neo4j-private.template.yaml` — same bastion, same NLB, same cluster ASGs, same SSM contract — except it does not create any VPC or subnets. It accepts `VpcId` and `PrivateSubnet1Id/2Id/3Id` and deploys into a caller-supplied VPC.

Two additional parameters control endpoint creation:

- **`CreateVpcEndpoints` (default `true`)** — when `true`, the template creates the four interface endpoints (`ssm`, `ssmmessages`, `logs`, `secretsmanager`) and a dedicated endpoint SG. When `false`, the caller supplies an existing endpoint SG via `ExistingEndpointSgId`; the template adds ingress rules from the Neo4j instances and bastion into that SG instead. Creating duplicate endpoints in a VPC that already has them fails the deployment — this flag prevents that.
- **`ExistingEndpointSgId`** — required when `CreateVpcEndpoints=false`. The stack wires ingress into this SG and publishes it as `vpc-endpoint-sg-id` in the SSM contract. A CFN `Rules` block enforces it is non-empty at deploy time.

In both paths the `vpc-endpoint-sg-id` SSM parameter points to the correct, functional SG — either the template-created one or the caller-supplied one.

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

# 5. AWS CLI (required by create-test-vpc.sh and teardown-test-vpc.sh)
aws --version
```

---

## Path A — Fresh VPC, Template Creates Endpoints (CI Gate)

### Phase 0: Create Test VPC (~2–3 min)

```bash
cd neo4j-ee
scripts/create-test-vpc.sh --region us-east-1
```

Creates a minimal private-networking VPC (`10.42.0.0/16`) with 3 private subnets (one per AZ), 3 NAT gateways, and all supporting resources. No interface endpoints — the template creates those in Phase 1.

**Writes**: `.deploy/vpc-<ts>.txt` with `VpcId`, `Subnet1Id`, `Subnet2Id`, `Subnet3Id`, `VpcCidr`, and all resource IDs needed for teardown.

**Pass criteria**: script exits 0; all three NAT gateways reach `available` state.

**Failure**: AZ enumeration fails if the region has fewer than 3 available AZs. All supported regions (`SUPPORTED_REGIONS` in `deploy.py`) have at least 3. If a NAT gateway gets stuck, check the public subnet's route table association.

### Phase 1: Deploy (10–20 min)

```bash
VPC_FILE=$(ls -t .deploy/vpc-*.txt | head -1)
read_vpc() { grep "^${1}" "$VPC_FILE" | sed 's/^[^=]*= *//' | tr -d '\r'; }

./deploy.py --mode ExistingVpc --region us-east-1 --number-of-servers 3 \
  --vpc-id    "$(read_vpc VpcId)"    \
  --subnet-1  "$(read_vpc Subnet1Id)" \
  --subnet-2  "$(read_vpc Subnet2Id)" \
  --subnet-3  "$(read_vpc Subnet3Id)" \
  --allowed-cidr "$(read_vpc VpcCidr)" \
  --create-vpc-endpoints true
```

**Writes**: `.deploy/<stack-name>.txt` with stack outputs (NLB DNS, bastion ID, password, SSM paths, `CreateVpcEndpoints=true`).

**Pass criteria**: CloudFormation reaches `CREATE_COMPLETE`. deploy.py waits for the waiter and exits 0.

**Failure**: If the stack hits `CREATE_FAILED`, check `/var/log/cloud-init-output.log` on any node via SSM send-command (bastion may not be up yet — use a node instance ID from the ASG directly).

### Phase 2: Preflight (45–75 s)

```bash
STACK=$(ls -t .deploy/test-ee-*.txt | head -1 | xargs basename | sed 's/\.txt$//')

cd validate-private
./scripts/preflight.sh "$STACK"
```

Runs 11 required checks + 1 informational:

1. CloudFormation stack status = `CREATE_COMPLETE` or `UPDATE_COMPLETE`
2. Bastion SSM PingStatus = Online
3. Neo4j Python driver installed on bastion
4. `cypher-shell` installed on bastion
5. Secret `neo4j/<stack>/password` exists in Secrets Manager
6. Contract SSM params: `vpc-id`, `nlb-dns`, `external-sg-id`, `password-secret-arn`, `vpc-endpoint-sg-id`
7. *(informational)* Operational SSM params: `region`, `stack-name`, `private-subnet-1-id`, `private-subnet-2-id`
8. VPC interface endpoints in state `available`: `secretsmanager`, `logs`, `ssm`, `ssmmessages`
9–12. Each endpoint reachable via curl from the bastion (expects HTTP 400/403/404 — unsigned request rejected by PrivateLink, not timed out)

**Pass criteria**: `FAIL_COUNT=0`. Exit 0.

**Failure**: Bastion not ready within 2–3 min of stack completion is the most common early failure — retry once. Endpoint reachability failures (checks 9–12) indicate a security group misconfiguration between `VpcEndpointSecurityGroup` and `Neo4jInternalSecurityGroup` or `Neo4jBastionSecurityGroup`.

### Phase 3: Basic Checks (~30 s)

```bash
uv run validate-private --stack "$STACK"
```

Runs 7 checks via the operator bastion:

1. **Bolt connectivity** — `RETURN 1 AS result` through NLB
2. **Server status** — `dbms.components()` returns `edition = enterprise`
3. **Listen address** — `server.default_listen_address = 0.0.0.0`
4. **Memory configuration** — heap + pagecache settings present
5. **Data directory** — `/var/lib/neo4j/data`
6. **APOC** — skipped unless `InstallAPOC=yes` in the outputs file
7. **Cluster roles** — `SHOW DATABASE neo4j YIELD serverID, writer` returns 3 rows, exactly 1 writer, all serverIDs distinct

**Pass criteria**: All checks `PASS`. Exit 0.

### Phase 3.5: Sample App Deploy (optional, background, ~3–5 min)

Start immediately after Phase 3 exits — runs while Phases 4 and 5 execute. Verifies that `vpc-id`, `external-sg-id`, and `vpc-endpoint-sg-id` are published correctly and reachable by an in-VPC Lambda.

```bash
cd ../sample-private-app
./deploy-sample-private-app.sh "${STACK}" &
APP_DEPLOY_PID=$!
```

**Pass criteria**: `aws cloudformation deploy` exits 0. Function URL and Validate URL are present in the output JSON.

**Teardown ordering note**: The sample app owns `SecurityGroupIngress` rules on the EE stack's security groups. Tear it down **before** the EE stack (Phase 6). Deleting the EE stack first will stall at security group deletion.

### Phase 4: Failover Suite (~10–15 min)

```bash
cd ../validate-private
uv run validate-private --stack "$STACK" --suite failover
```

Four sequential cases using `systemctl stop`/`start` via SSM:

| Case | What it does | Runtime |
|---|---|---|
| `follower-with-data` | Stop a follower, write data, restart, verify data visible | ~60 s |
| `leader` | Stop the leader, verify election, write on new leader | ~90 s |
| `rolling` | Stop each node in turn; cluster stays available throughout | ~4–15 min |
| `reads` | Stop two followers; verify reads still served by remaining nodes | ~90 s |

**Pass criteria**: All 4 cases report `PASS`. Exit 0.

### Phase 5: Resilience Suite (~20–25 min)

```bash
uv run validate-private --stack "$STACK" --suite resilience
```

Two cases that terminate EC2 instances and wait for ASG replacement:

| Case | What it does | Timeout |
|---|---|---|
| `single-loss` | Terminate 1 node; verify EBS reattach + sentinel data intact + quorum reforms | 900 s |
| `total-loss` | Terminate all 3 nodes simultaneously; verify all 3 volumes reattach + sentinel intact | 1200 s |

Each case writes a sentinel file to the data volume before termination and verifies it survives on the replacement instance.

**Pass criteria**: Both cases `PASS`. Exit 0.

### Phase 5.5: Sample App Tests (optional, ~2–3 min)

```bash
wait $APP_DEPLOY_PID   # wait for Phase 3.5 background deploy

cd ../sample-private-app
./invoke.sh    # write fintech graph, get cluster health report
./validate.sh  # stop a follower, wait for recovery (~60–120 s)
```

**Pass criteria**: Both scripts return JSON with no `error` key. Exit 0.

### Phase 6: Teardown EE Stack (5–10 min)

```bash
# Sample app FIRST — it owns SG ingress rules on the EE stack
cd ../sample-private-app
./teardown-sample-private-app.sh "${STACK}"

cd ..
./teardown.sh --delete-volumes "${STACK}"
```

Deletes: CloudFormation stack, SSM parameters, password secret (force), retained EBS data volumes, `.deploy/<stack>.txt`.

**Pass criteria**: Stack reaches `DELETE_COMPLETE`. Exit 0.

### Phase 7: Teardown Test VPC (2–3 min)

```bash
scripts/teardown-test-vpc.sh "$(basename "$VPC_FILE" .txt)"
```

Deletes resources in reverse creation order: interface endpoints → NAT gateways → EIPs → subnets → private route tables → IGW → VPC → `.deploy/vpc-<ts>.txt`. NAT gateway deletion takes 60–90 s.

**Pass criteria**: VPC deleted; `vpc-<ts>.txt` removed. Exit 0.

---

## Path B — VPC with Pre-Existing Endpoints (Weekly / Pre-Release)

Path B validates that the template correctly skips endpoint creation when `CreateVpcEndpoints=false`, wires the Neo4j instances and bastion into a caller-supplied endpoint SG, and publishes that SG as `vpc-endpoint-sg-id` in the SSM contract. Endpoint reachability (preflight checks 9–12) confirms the wiring is correct.

### Phase 0: Create Test VPC with Endpoints (~5–10 min)

```bash
cd neo4j-ee
scripts/create-test-vpc.sh --region us-east-1 --with-endpoints
```

Creates the same VPC as Path A, plus four interface endpoints (`ssm`, `ssmmessages`, `logs`, `secretsmanager`) in the private subnets with a shared endpoint SG (`ingress 443 from VPC CIDR`).

**Writes**: `.deploy/vpc-<ts>.txt` — same fields as Path A plus `WithEndpoints=true` and `EndpointSgId=sg-...`.

**Pass criteria**: Script exits 0; all four endpoints reach `available` state.

### Phase 1: Deploy (5–10 min)

```bash
VPC_FILE=$(ls -t .deploy/vpc-*.txt | head -1)
read_vpc() { grep "^${1}" "$VPC_FILE" | sed 's/^[^=]*= *//' | tr -d '\r'; }

./deploy.py --mode ExistingVpc --region us-east-1 --number-of-servers 1 \
  --vpc-id    "$(read_vpc VpcId)"    \
  --subnet-1  "$(read_vpc Subnet1Id)" \
  --allowed-cidr "$(read_vpc VpcCidr)" \
  --create-vpc-endpoints false \
  --existing-endpoint-sg-id "$(read_vpc EndpointSgId)"
```

The template does not create endpoints or `VpcEndpointSecurityGroup`. It adds two `AWS::EC2::SecurityGroupIngress` rules (ingress 443) into `EndpointSgId` — one from `Neo4jInternalSecurityGroup`, one from `Neo4jBastionSecurityGroup`. The SSM contract publishes `EndpointSgId` as `vpc-endpoint-sg-id`.

**Writes**: `.deploy/<stack-name>.txt` with `CreateVpcEndpoints=false` and `ExistingEndpointSgId=<sg-id>`.

**Pass criteria**: CloudFormation reaches `CREATE_COMPLETE`. Exit 0.

### Phase 1.5: Wire Bastion SG into Endpoint SG (<1 min)

The template wired the bastion SG ingress rule at stack creation time, but the test VPC's pre-existing endpoint SG was created with ingress only from `VPC_CIDR`. The bastion SG must be explicitly authorized before preflight runs endpoint reachability checks.

```bash
STACK=$(ls -t .deploy/test-ee-*.txt | head -1 | xargs basename | sed 's/\.txt$//')
REGION=us-east-1
ENDPOINT_SG_ID=$(read_vpc EndpointSgId)

BASTION_SG=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='Neo4jBastionSecurityGroupId'].OutputValue" \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id  "$ENDPOINT_SG_ID" \
  --protocol  tcp --port 443 \
  --source-group "$BASTION_SG" \
  --region    "$REGION"
```

This rule is removed automatically when `teardown-test-vpc.sh` deletes the VPC.

**Pass criteria**: `authorize-security-group-ingress` exits 0.

### Phase 2: Preflight (45–75 s)

```bash
cd validate-private
./scripts/preflight.sh "$STACK"
```

Same 11 required checks as Path A. The critical difference is in checks 9–12: the bastion reaches the **pre-existing** endpoints through the ingress rule added in Phase 1.5. Check 6 verifies that `vpc-endpoint-sg-id` equals `EndpointSgId` (the pre-existing SG), not a template-created SG.

**Pass criteria**: `FAIL_COUNT=0`. Exit 0.

**Failure**: Endpoint reachability failures in checks 9–12 almost always mean Phase 1.5 was skipped or the `authorize-security-group-ingress` call used the wrong SG ID. Verify `$BASTION_SG` and `$ENDPOINT_SG_ID` are non-empty and correct.

### Phase 3: Basic Checks (~30 s)

```bash
uv run validate-private --stack "$STACK"
```

Same 7 checks as Path A. With 1 server, check 7 (cluster roles) returns 1 row: 1 writer, 0 followers, all serverIDs distinct — this is a `PASS`.

**Pass criteria**: All checks `PASS`. Exit 0.

### Phase 4: Teardown EE Stack (2–3 min)

```bash
cd ..
./teardown.sh --delete-volumes "$STACK"
```

Stack deletion removes the two `AWS::EC2::SecurityGroupIngress` rules from `EndpointSgId` — no manual cleanup needed.

**Pass criteria**: Stack reaches `DELETE_COMPLETE`. Exit 0.

### Phase 5: Teardown Test VPC (2–3 min)

```bash
scripts/teardown-test-vpc.sh "$(basename "$VPC_FILE" .txt)"
```

**Pass criteria**: VPC deleted; `vpc-<ts>.txt` removed. Exit 0.

---

## Path A — Combined Run

```bash
set -euo pipefail
cd neo4j-ee
REGION=us-east-1

# Kill background app deploy and print teardown reminder on early exit
trap '
  if [[ -n "${APP_DEPLOY_PID:-}" ]]; then
    kill "${APP_DEPLOY_PID}" 2>/dev/null || true
    echo "Background app deploy killed. Tear down in order:"
    echo "  cd neo4j-ee/sample-private-app && ./teardown-sample-private-app.sh ${STACK:-<stack>}"
    echo "  cd neo4j-ee && ./teardown.sh --delete-volumes ${STACK:-<stack>}"
    echo "  neo4j-ee/scripts/teardown-test-vpc.sh ${VPC_NAME:-<vpc>}"
  fi
' EXIT

# Phase 0: Create test VPC
scripts/create-test-vpc.sh --region "$REGION"
VPC_FILE=$(ls -t .deploy/vpc-*.txt | head -1)
VPC_NAME=$(basename "$VPC_FILE" .txt)
read_vpc() { grep "^${1}" "$VPC_FILE" | sed 's/^[^=]*= *//' | tr -d '\r'; }

# Phase 1: Deploy
./deploy.py --mode ExistingVpc --region "$REGION" --number-of-servers 3 \
  --vpc-id    "$(read_vpc VpcId)"    \
  --subnet-1  "$(read_vpc Subnet1Id)" \
  --subnet-2  "$(read_vpc Subnet2Id)" \
  --subnet-3  "$(read_vpc Subnet3Id)" \
  --allowed-cidr "$(read_vpc VpcCidr)" \
  --create-vpc-endpoints true

# Capture stack name immediately — don't rely on ls -t after this point
STACK=$(ls -t .deploy/test-ee-*.txt | head -1 | xargs basename | sed 's/\.txt$//')

# Phase 2: Preflight
cd validate-private
./scripts/preflight.sh "$STACK"

# Phase 3: Basic checks
uv run validate-private --stack "$STACK"

# Phase 3.5: Start sample app deploy in background (optional)
cd ../sample-private-app
./deploy-sample-private-app.sh "$STACK" &
APP_DEPLOY_PID=$!

# Phase 4 + 5: Failover then resilience (while sample app deploys)
cd ../validate-private
uv run validate-private --stack "$STACK" --suite all

# Phase 5.5: Sample app tests (optional — wait for background deploy first)
wait $APP_DEPLOY_PID
cd ../sample-private-app
./invoke.sh
./validate.sh

# Phase 6: Teardown — sample app before EE stack
./teardown-sample-private-app.sh "$STACK"
cd ..
./teardown.sh --delete-volumes "$STACK"

# Phase 7: Teardown test VPC
scripts/teardown-test-vpc.sh "$VPC_NAME"
```

Total wall-clock time: **55–80 min** (dominated by ASG replacement in Phase 5; sample app deploy overlaps with that window).

---

## Path B — Combined Run

```bash
set -euo pipefail
cd neo4j-ee
REGION=us-east-1

# Phase 0: Create test VPC with pre-existing endpoints
scripts/create-test-vpc.sh --region "$REGION" --with-endpoints
VPC_FILE=$(ls -t .deploy/vpc-*.txt | head -1)
VPC_NAME=$(basename "$VPC_FILE" .txt)
read_vpc() { grep "^${1}" "$VPC_FILE" | sed 's/^[^=]*= *//' | tr -d '\r'; }
ENDPOINT_SG_ID=$(read_vpc EndpointSgId)

# Phase 1: Deploy (1-node, skip endpoint creation)
./deploy.py --mode ExistingVpc --region "$REGION" --number-of-servers 1 \
  --vpc-id    "$(read_vpc VpcId)"    \
  --subnet-1  "$(read_vpc Subnet1Id)" \
  --allowed-cidr "$(read_vpc VpcCidr)" \
  --create-vpc-endpoints false \
  --existing-endpoint-sg-id "$ENDPOINT_SG_ID"

STACK=$(ls -t .deploy/test-ee-*.txt | head -1 | xargs basename | sed 's/\.txt$//')

# Phase 1.5: Wire bastion SG into the pre-existing endpoint SG
BASTION_SG=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='Neo4jBastionSecurityGroupId'].OutputValue" \
  --output text)
aws ec2 authorize-security-group-ingress \
  --group-id     "$ENDPOINT_SG_ID" \
  --protocol     tcp --port 443 \
  --source-group "$BASTION_SG" \
  --region       "$REGION"

# Phase 2: Preflight (endpoint reachability confirms the wiring)
cd validate-private
./scripts/preflight.sh "$STACK"

# Phase 3: Basic checks (cluster roles: 1 writer, 0 followers — PASS for 1-node)
uv run validate-private --stack "$STACK"

# Phase 4: Teardown EE stack (removes SecurityGroupIngress rules from EndpointSgId)
cd ..
./teardown.sh --delete-volumes "$STACK"

# Phase 5: Teardown test VPC
scripts/teardown-test-vpc.sh "$VPC_NAME"
```

Total wall-clock time: **15–25 min**.

---

## Parallel Test Isolation

When running two or more full test runs simultaneously (e.g., Path A vs Path B, or `t3` vs `r8i`), the default stack and VPC file selectors (`ls -t ... | head -1`) are unreliable if two runs write files concurrently.

**Fix**: always capture `STACK` and `VPC_FILE` immediately after each deploy script exits and pass them explicitly to every subsequent command — exactly as the combined run scripts above do.

All resources are isolated by stack name and timestamp:

| Resource | Scoping |
|---|---|
| CloudFormation stacks | `test-ee-<timestamp>` |
| VPC | `vpc-<timestamp>.txt` in `.deploy/` |
| SSM parameters | `/neo4j-ee/<stack>/` prefix |
| Secrets Manager | `neo4j/<stack>/password` |
| EBS volumes | Tagged with `StackID` |
| App stack (optional) | `neo4j-sample-private-app-<ee-stack>` |

The VPC CIDR (`10.42.0.0/16`) is identical across runs; this is fine because each VPC is independent. EC2 enforces no cross-VPC uniqueness constraint on CIDRs.

---

## Failure Handling

| Failure point | Where to look | Action |
|---|---|---|
| Phase 0: NAT gateway stuck | `describe-nat-gateways` | Check public subnet/EIP allocation; re-run create-test-vpc.sh and teardown the partial VPC |
| Phase 0: <3 AZs in region | Script exits with error | Region is not supported; pick another from `SUPPORTED_REGIONS` |
| Phase 1: stack stuck at CREATE | `/var/log/cloud-init-output.log` (SSM send-command to node) | Check UserData; `teardown.sh` if unrecoverable, then teardown VPC |
| Phase 1.5 (Path B): wrong SG ID | Empty `$BASTION_SG` or `$ENDPOINT_SG_ID` | Verify the VPC file and CFN outputs; re-run authorize-security-group-ingress manually |
| Phase 2: bastion not online | Wait 2–3 min; retry preflight | If still failing, inspect bastion UserData via SSM send-command |
| Phase 2: endpoint reachability (Path A) | `VpcEndpointSecurityGroup` ingress rules | Verify `Neo4jInternalSecurityGroup` and `Neo4jBastionSecurityGroup` are in the endpoint SG ingress |
| Phase 2: endpoint reachability (Path B) | `EndpointSgId` ingress rules | Confirm Phase 1.5 ran; check `describe-security-groups` for the 443 ingress from `$BASTION_SG` |
| Phase 3–5: Cypher failure | `validate-private` stdout + `/var/log/neo4j/debug.log` (SSM) | Leave stack up for inspection; teardown in order when done |
| Phase 4: ASG timeout | ASG activity events | Extend `--timeout`; check `/var/log/cloud-init-output.log` on new instance |

**Teardown order on failure** (Path A with sample app): always `teardown-sample-private-app.sh` first, then `teardown.sh --delete-volumes`, then `teardown-test-vpc.sh`. Reversing any step can leave orphaned SG ingress rules that stall deletion.

**Teardown order on failure** (all other paths): `teardown.sh --delete-volumes <stack>`, then `teardown-test-vpc.sh <vpc>`. The EE stack deletion removes any `SecurityGroupIngress` rules it owns from the pre-existing endpoint SG (Path B), so teardown-test-vpc.sh can proceed cleanly.

Leave stacks running for post-mortem. Once investigation is complete:

```bash
# Path A with sample app
cd neo4j-ee/sample-private-app && ./teardown-sample-private-app.sh <stack>
cd neo4j-ee && ./teardown.sh --delete-volumes <stack>
neo4j-ee/scripts/teardown-test-vpc.sh <vpc-name>

# All other paths
cd neo4j-ee && ./teardown.sh --delete-volumes <stack>
neo4j-ee/scripts/teardown-test-vpc.sh <vpc-name>
```
