# Neo4j Private Cluster — Lambda Demo App

The neo4j-ee stack deploys its cluster in private subnets behind an internal NLB with no public IPs. [`OPERATOR_GUIDE.md`](../OPERATOR_GUIDE.md) covers how to connect a laptop via SSM port-forwarding. This app answers a different question: how does an application workload connect to that same cluster from inside the VPC?

For the full architecture, security group wiring, and design decisions behind this pattern, see [`APP_GUIDE.md`](../APP_GUIDE.md).

The answer is two Python 3.13 Lambdas in the cluster's private subnets, each behind its own IAM-authenticated Function URL:

- **`invoke.sh`** → the main Lambda. Connects via `neo4j://` (plain) or `neo4j+ssc://` (TLS, self-signed cert) on the internal NLB DNS, creates a small fintech graph, returns a cluster health report.
- **`validate.sh`** → the resilience Lambda. Picks a follower, stops `neo4j.service` via SSM, polls `SHOW SERVERS` until that member goes `Unavailable`, starts it again, polls until it returns to `Available`, and reports the timings.

Each Lambda has its own IAM role and log group so SSM/EC2 permissions stay off the main invoke path.

## Architecture

```
Internet
    │
    ▼
Lambda Function URL  (HTTPS, AWS_IAM auth)
    │
    └─ Lambda  (private subnet, Neo4j VPC)
           │  NEO4J_SSM_NLB_PATH → /neo4j-ee/<stack>/nlb-dns
           │  NEO4J_SECRET_ARN   → neo4j/<stack>/password
           ▼
    Internal NLB  (neo4j[+ssc]://<nlb-dns>:7687)
           │
    ┌──────┴──────┐
    ▼             ▼             ▼
  Neo4j-1      Neo4j-2       Neo4j-3
  (private subnet, each AZ)
```

The Lambda's security group has two egress rules: TCP 7687 to the Neo4j external SG for Bolt, and TCP 443 to the VPC interface endpoint SG for SSM and Secrets Manager API calls. The password secret is owned by the EE CloudFormation stack; the Lambda imports it by ARN rather than creating a new one.

## Prerequisites

- An existing neo4j-ee Private-mode stack (run `../deploy.py --marketplace --mode Private`)
- Python 3 and pip installed locally
- `AWS_PROFILE` pointing to an account with permissions for CloudFormation, Lambda, IAM, EC2, S3, SSM, and Secrets Manager

## Workflow

All scripts run from the `sample-private-app/` directory:

```bash
# Deploy against the most recent EE stack
./deploy-sample-private-app.sh

# Or target a specific EE stack
./deploy-sample-private-app.sh test-ee-1776575131

# Invoke the Lambda
./invoke.sh

# Run the resilience test (stops a follower, waits for recovery; ~60-120s end-to-end)
./validate.sh

# Tear down (always do this BEFORE tearing down the parent EE stack)
./teardown-sample-private-app.sh
```

`deploy-sample-private-app.sh` reads the EE stack's SSM parameters, packages the Lambda, uploads it to a deploy S3 bucket, runs `aws cloudformation deploy`, and writes the Function URL to `/neo4j-sample-private-app/<stack>/function-url` in SSM and `../.deploy/sample-private-app-<ee-stack>.json` locally. It also generates `invoke.sh` in the same directory.

The EE stack's SSM parameters (`/neo4j-ee/<stack>/vpc-id`, `nlb-dns`, `private-subnet-1-id`, `private-subnet-2-id`, `external-sg-id`, `password-secret-arn`) are CloudFormation resources — they exist for the lifetime of the EE stack and need no manual management.

### Teardown ordering

**Always delete this stack before tearing down the parent EE stack.** `sample-private-app.template.yaml` owns two `AWS::EC2::SecurityGroupIngress` resources on the EE stack's security groups (Bolt ingress on the external SG, HTTPS ingress on the VPC endpoint SG). If the EE stack is deleted first, those SG rules become orphaned and the EE stack's `DELETE_IN_PROGRESS` will stall.

## What the Lambda Returns

```json
{
  "tls_enabled": true,
  "bolt_scheme": "neo4j+ssc",
  "edition": "enterprise",
  "nodes_created": 10,
  "relationships_created": 9,
  "graph_sample": [
    {"customer": "Alice Chen", "account_type": "checking", "amount": 2400.0,  "merchant": "StripePayments"},
    {"customer": "Bob Patel",  "account_type": "checking", "amount": 18700.0, "merchant": "AmazonAWS"},
    {"customer": "Carol Wu",   "account_type": "savings",  "amount": 6500.0,  "merchant": "WeWorkSpaces"}
  ],
  "servers": [
    {"name": "...", "state": "Enabled", "health": "Available"},
    {"name": "...", "state": "Enabled", "health": "Available"},
    {"name": "...", "state": "Enabled", "health": "Available"}
  ],
  "routing_table": {
    "writers": 1,
    "readers": 2
  }
}
```

The Function URL wraps this as `{"statusCode": 200, "headers": {...}, "body": "<json string>"}`; `invoke.sh` pipes the body through `python3 -m json.tool` for readability.

On first invocation, nodes and relationships are created. Subsequent invocations use `MERGE`, so the graph stays idempotent. Several queries confirm distinct cluster properties: `dbms.components()` verifies Enterprise Edition, `dbms.routing.getRoutingTable({}, 'neo4j')` confirms a leader has been elected and the routing table is fully populated, `SHOW SERVERS` (on the system database) reports per-node health, and a `Customer → Account → Transaction → Merchant` traversal returns `graph_sample` to prove the graph is queryable end-to-end.

## Resilience Test (`validate.sh`)

`validate.sh` calls the second Lambda's Function URL. That Lambda:

1. Calls `CALL dbms.cluster.overview()` over the NLB to find the LEADER and FOLLOWER server UUIDs for the `neo4j` database.
2. Calls `ec2:DescribeInstances` filtered by `tag:aws:cloudformation:stack-name = <Neo4j EE stack>` to list the three cluster EC2 instances.
3. Maps instance-ID → Neo4j server UUID by running `cat /var/lib/neo4j/data/server_id` on all three instances in parallel via SSM `send-command`.
4. Picks a random follower, runs `systemctl stop neo4j` via SSM, polls `SHOW SERVERS` until that server's `health` is no longer `Available` (expect `Unavailable` within ~10–20s).
5. Runs `systemctl start neo4j` via SSM, polls `SHOW SERVERS` until `health == 'Available'` again (expect ~20–60s for Raft rejoin).
6. Returns a JSON report with timings.

Sample output:

```json
{
  "ee_stack": "test-ee-1776575131",
  "target_instance_id": "i-0abc...",
  "target_server_uuid": "8b2f...",
  "leader_server_uuid": "1a3e...",
  "time_to_stop_issued_s": 1.12,
  "time_to_unavailable_s": 8.34,
  "observed_stop_health": "Unavailable",
  "time_to_start_issued_s": 0.98,
  "time_to_available_s": 31.47,
  "observed_start_health": "Available",
  "final_servers": [
    {"name": "1a3e...", "state": "Enabled", "health": "Available"},
    {"name": "8b2f...", "state": "Enabled", "health": "Available"},
    {"name": "c7d1...", "state": "Enabled", "health": "Available"}
  ]
}
```

### IAM scoping

The resilience Lambda's role has `ssm:SendCommand` on `AWS-RunShellScript` scoped to EC2 instances via `aws:ResourceTag/aws:cloudformation:stack-name = <Neo4jStackName>` — so it can only issue shell commands to instances launched by the paired EE stack. `ec2:DescribeInstances` is `*` (the service doesn't support resource-level authorization) but is read-only. The main invoke Lambda has none of these permissions.

### Lambda timeout

The resilience Lambda is configured with `Timeout: 300` (5 minutes). `validate.sh` uses `curl --max-time 310` so the HTTP call doesn't cut the function off before it finishes. Function URLs have their own hard ceiling of 900s; the 300s budget is a comfortable margin for the stop/start cycle.

## Invoking from a Laptop

The Function URL requires a Sigv4-signed request. `invoke.sh` handles this via `curl --aws-sigv4`:

```bash
./invoke.sh
```

To call it manually:

```bash
FUNCTION_URL=$(aws ssm get-parameter \
  --name "/neo4j-sample-private-app/<app-stack>/function-url" \
  --query "Parameter.Value" --output text)

eval "$(aws configure export-credentials --format env 2>/dev/null)"

curl --silent --aws-sigv4 "aws:amz:${AWS_DEFAULT_REGION}:lambda" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
  -H "Content-Type: application/json" \
  "${FUNCTION_URL}" | python3 -m json.tool
```

`curl --aws-sigv4` ships with macOS Ventura (curl 7.88) and later.

## Project Structure

```
sample-private-app/
├── deploy-sample-private-app.sh      # Package Lambdas, deploy CFN stack, generate invoke.sh + validate.sh
├── teardown-sample-private-app.sh    # Delete CFN stack, S3 zip versions, local files
├── invoke.sh                         # Generated at deploy time (calls the main Lambda)
├── validate.sh                       # Generated at deploy time (calls the resilience Lambda)
├── sample-private-app.template.yaml  # CloudFormation template (both Lambdas, SGs, IAM, Function URLs)
└── lambda/
    ├── handler.py                    # lambda_handler (main) + resilience_handler (stop/start a follower)
    └── requirements.txt              # neo4j>=6,<7
```

## Bolt TLS

When the EE stack is deployed with `--tls` (`DeploymentMode=Private` + TLS), the NLB listener requires TLS on port 7687 using a self-signed certificate whose SAN matches the NLB DNS name. `deploy-sample-private-app.sh` detects the `BoltTlsSecretArn` output from the EE stack and passes `BoltTlsEnabled=true` to CloudFormation, which sets `NEO4J_BOLT_TLS=true` in the Lambda environment.

The Lambda then uses the `neo4j+ssc://` URI scheme (server-side TLS, self-signed cert accepted). This is the correct scheme for internal VPC connections where the certificate is self-signed but the channel must be encrypted. No certificate file or custom SSL context is needed — the scheme alone instructs the driver to accept self-signed certs.

| `NEO4J_BOLT_TLS` | URI scheme | Encryption |
|---|---|---|
| unset / `false` | `neo4j://` | None |
| `true` | `neo4j+ssc://` | TLS, self-signed cert accepted |

## Deploy Bucket

`deploy-sample-private-app.sh` creates (once per account/region) an S3 bucket named `neo4j-sample-private-app-deploy-<account>-<region>` with versioning enabled. Object versioning is used to force Lambda code updates on every deploy without changing the S3 key. `teardown-sample-private-app.sh` deletes all versions of the stack's zip key but leaves the bucket for reuse across stacks.

## Key Design Decisions

**Plain CloudFormation, not CDK.** The AWS Organizations SCP in this account blocks `iam:AttachRolePolicy` on CDK's default bootstrap role name pattern (`cdk-*-cfn-exec-role-*`), making CDK bootstrap impossible. Plain CloudFormation with `--capabilities CAPABILITY_IAM` is not affected.

**Direct boto3 at cold start, not the Parameters and Secrets Lambda Extension.** The extension adds a region-specific Layer ARN that must be kept current and adds local HTTP proxy overhead. For a demo invoked infrequently, direct boto3 calls are simpler and clearer.

**Driver cached across invocations with auth-rotation fallback.** The Neo4j driver is created lazily on first invocation and reused on warm starts. If the cached driver hits an `AuthError` (e.g. the password secret rotated), the handler closes it, rebuilds a fresh driver, and retries once.

**S3 object versioning forces code updates.** The deploy bucket has versioning enabled; each `put-object` returns a new `VersionId` that is passed as `LambdaS3ObjectVersion`. CloudFormation sees the version change and updates the function without needing to rotate the S3 key.

**Function URL auth is `AWS_IAM`.** An unsigned Function URL accepts requests from any caller who knows the URL. Since the Lambda writes to Neo4j, that is an unauthenticated write path. `AWS_IAM` requires Sigv4 signing using existing AWS credentials, with no extra infrastructure.
