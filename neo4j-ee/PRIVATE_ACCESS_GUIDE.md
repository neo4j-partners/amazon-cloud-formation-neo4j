# Private Deployment Operator Guide

Private mode places Neo4j instances in private subnets with no public IP and an internal Network Load Balancer. There is no direct route from an operator workstation to the cluster. Access runs through an operator bastion: a `t4g.nano` instance in the same VPC that carries SSM sessions to the NLB, and executes Cypher queries on the cluster using its own IAM role.

This guide covers everything an operator needs to verify, query, and troubleshoot a Private-mode stack using only AWS credentials and a stack name.

---

## Prerequisites

**AWS CLI v2** and the **Session Manager Plugin** must be installed:

```bash
# Session Manager Plugin (required for start-session commands)
brew install --cask session-manager-plugin

# Verify
aws --version
session-manager-plugin --version
```

The IAM role or user running these commands needs:

| Permission | Resource |
|---|---|
| `cloudformation:DescribeStacks`, `cloudformation:DescribeStackResources` | The stack ARN |
| `ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:StartSession`, `ssm:DescribeInstanceInformation` | The bastion instance |
| `ssm:GetParameter`, `ssm:GetParametersByPath` | `/neo4j-ee/<stack-name>/*` |
| `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` | `neo4j/<stack-name>/password` |

These are the same permissions the bastion itself uses. If `preflight.sh` passes but `validate-private` fails on a permissions error, the gap is in the bastion's IAM role, not the operator's.

---

## 1. Verify the stack is ready

Before running any other script, confirm that V11's server-side machinery is in place:

```bash
cd neo4j-ee
./scripts/preflight.sh
```

Or for a specific stack:

```bash
./scripts/preflight.sh test-ee-1776575131
```

Expected output when everything is ready:

```
=== Preflight Checks ===

  Stack:   test-ee-1776575131
  Region:  us-east-1
  Bastion: i-0abc123def456789

  [PASS] Stack status = CREATE_COMPLETE
  [PASS] Bastion SSM PingStatus = Online
  [PASS] neo4j Python driver installed on bastion
  [PASS] cypher-shell installed on bastion
  [PASS] Secret 'neo4j/test-ee-1776575131/password' exists
  [PASS] All 8 SSM config params under /neo4j-ee/test-ee-1776575131/

  6 passed, 0 failed
  All checks passed.
```

If the bastion checks fail immediately after a fresh deploy, the bastion's UserData may still be running. Wait 2–3 minutes and retry — the script will tell you what to check.

---

## 2. Retrieve the password

The Neo4j password lives in Secrets Manager at `neo4j/<stack-name>/password`. The stack's `.deploy/` file also contains it, but the Secrets Manager path is the authoritative one for operator use:

```bash
./scripts/get-password.sh
```

The password is printed to stdout, so you can capture it:

```bash
PASSWORD=$(./scripts/get-password.sh 2>/dev/null)
```

---

## 3. Interactive admin shell (preferred for writes)

For any operation that writes to the database, use the admin shell. It opens `cypher-shell` on the bastion with a `neo4j://` URI, which means the Neo4j driver fetches the routing table and directs writes to the current leader automatically — no coin-flip routing.

```bash
./scripts/admin-shell.sh
```

The password is resolved on the bastion using the bastion's IAM role. It does not appear on the laptop or in CloudTrail. Once connected:

```
neo4j@neo4j> CREATE (n:Test {msg: "hello"}) RETURN n;
neo4j@neo4j> MATCH (n:Test) DELETE n;
neo4j@neo4j> :exit
```

Type `:exit` or press Ctrl-D to close the session.

---

## 4. Browser access (reads and light exploration)

To open Neo4j Browser:

```bash
./scripts/browser-tunnel.sh
```

Once the tunnel is open, go to `http://localhost:7474` in a browser. The tunnel connects to the NLB on port 7474; the NLB routes each new TCP connection to a cluster node.

Writes through Neo4j Browser go to whichever node the NLB selects on each new connection. That node may not be the current leader, which produces a `NotALeader` error on write. For writes, use the admin shell (section 3) instead.

---

## 5. Ad-hoc queries

For one-off queries from the command line:

```bash
./scripts/run-cypher.sh "CALL dbms.components() YIELD name, versions, edition RETURN name, versions[0] AS version, edition"
```

Output is JSON:

```json
[{"name": "Neo4j Kernel", "version": "5.26.0", "edition": "enterprise"}]
```

With a specific stack name:

```bash
./scripts/run-cypher.sh test-ee-1776575131 "MATCH (n) RETURN count(n) AS total"
```

Pipe to `jq` for formatting:

```bash
./scripts/run-cypher.sh "SHOW SERVERS YIELD serverId, address, role" | jq .
```

---

## 6. Smoke tests

Run a write smoke test before relying on the cluster for real traffic:

```bash
./scripts/smoke-write.sh
```

This runs 20 `CREATE ... DELETE` iterations through the cluster via the bastion. Each iteration uses a fresh driver connection so the routing table is exercised. At N=20, a single routing failure in the pool is statistically certain to surface at least one error.

For more iterations:

```bash
./scripts/smoke-write.sh test-ee-1776575131 50
```

---

## 7. Run the full validation suite

```bash
cd neo4j-ee/validate-private
uv run validate-private
```

Or for a specific stack:

```bash
uv run validate-private --stack test-ee-1776575131
```

The suite runs 6 checks via the bastion: Bolt connectivity, APOC (if installed), server edition, listen address, memory configuration, and data directory. Each check takes 3–5 seconds (SSM command latency). Total time under 35 seconds.

Expected output on a healthy stack:

```
=== Neo4j EE Private Validator ===

  Stack:   test-ee-1776575131
  Region:  us-east-1
  Bastion: i-0abc123def456789
  NLB:     internal-xxxx.elb.amazonaws.com

--- Test 1: Bolt connectivity ---
  PASS: Bolt connected via bastion, Cypher returned: 1  (4.2s)

--- Test 2: Neo4j server status ---
  PASS: Neo4j Kernel 5.26.0 (enterprise)  (3.8s)

...

  RESULT: All 6 tests PASSED  (total: 28.4s)
```

---

## 8. Troubleshooting

**"No deployment found"**
No `.deploy/*.txt` file exists. Run `deploy.sh` first, or pass the stack name explicitly.

**"Bastion SSM PingStatus = Online" fails**
The bastion's UserData may still be running (common in the first 3 minutes after stack creation). Check the bastion's SSM status directly:
```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=<bastion-id>" \
  --region <region>
```
If `PingStatus` is not `Online` after 10 minutes, check the bastion's IAM role for `AmazonSSMManagedInstanceCore` and verify the VPC has `ssm` and `ssmmessages` interface endpoints.

**"session-manager-plugin: command not found"**
```bash
brew install --cask session-manager-plugin
```
See [AWS install instructions](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for non-macOS platforms.

**"AccessDenied" on `GetSecretValue` or `GetParameter`**
The bastion's IAM role does not have access to the secret or SSM parameter for this stack. Check that the role policy covers `neo4j/<stack-name>/password` and `/neo4j-ee/<stack-name>/*`. Re-deploying the stack re-creates the IAM policy with the correct scope.

**"Secret not found"**
The stack was torn down. `teardown.sh` force-deletes the secret immediately to unblock re-deployment. If the stack is still up, run `preflight.sh` to confirm the secret exists.

**"NotALeader" error in Neo4j Browser**
The NLB routed a write to a follower. Use `admin-shell.sh` for writes — `neo4j://` routing directs writes to the leader automatically.

**Bastion Python checks fail but SSM is Online**
The bastion's UserData finished but package installation failed. Check `/var/log/cloud-init-output.log` on the bastion:
```bash
aws ssm send-command \
  --instance-ids <bastion-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -50 /var/log/cloud-init-output.log"]' \
  --region <region>
```
Then retrieve with `aws ssm get-command-invocation`.
