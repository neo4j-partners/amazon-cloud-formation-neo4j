# Neo4j Private Cluster — Lambda Demo App

The neo4j-ee stack deploys its cluster in private subnets behind an internal NLB with no public IPs. [`OPERATOR_GUIDE.md`](../OPERATOR_GUIDE.md) covers how to connect a laptop via SSM port-forwarding. This app answers a different question: how does an application workload connect to that same cluster from inside the VPC?

For the full architecture, security group wiring, and design decisions behind this pattern, see [`APP_GUIDE.md`](../APP_GUIDE.md).

The answer is a Python Lambda in the cluster's private subnets. It connects via `neo4j://` (plain) or `neo4j+ssc://` (TLS, self-signed cert) on the internal NLB DNS, creates a small fintech graph, then returns a cluster health report. A Lambda Function URL with `authType: AWS_IAM` exposes it publicly without requiring API Gateway.

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

On first invocation, nodes and relationships are created. Subsequent invocations use `MERGE`, so the graph stays idempotent. Three queries confirm distinct cluster properties: `dbms.components()` verifies Enterprise Edition, `SHOW SERVERS` (on the system database) reports per-node health, and `dbms.routing.getRoutingTable({})` confirms a leader has been elected and the routing table is fully populated.

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
├── deploy-sample-private-app.sh      # Package Lambda, deploy CFN stack, generate invoke.sh
├── teardown-sample-private-app.sh    # Delete CFN stack, SSM param, S3 zip, local files
├── force-delete-lambda-enis.sh       # Unblock stuck stack delete (VPC ENI cleanup)
├── invoke.sh                         # Generated at deploy time
├── sample-private-app.template.yaml  # CloudFormation template (Lambda, SG, IAM, Function URL)
└── lambda/
    ├── handler.py                    # Lambda handler (connect, merge, check, report)
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

**Plain CloudFormation, not CDK.** The AWS Organizations SCP in this account blocks `iam:AttachRolePolicy` on CDK's default bootstrap role name pattern (`cdk-*-cfn-exec-role-*`), making CDK bootstrap impossible. Plain CloudFormation with `--capabilities CAPABILITY_IAM` is not affected. See `LAMBDA_PAINS.md` for the full investigation.

**Direct boto3 at cold start, not the Parameters and Secrets Lambda Extension.** The extension adds a region-specific Layer ARN that must be kept current and adds local HTTP proxy overhead. For a demo invoked infrequently, direct boto3 calls are simpler and clearer.

**Function URL auth is `AWS_IAM`.** An unsigned Function URL accepts requests from any caller who knows the URL. Since the Lambda writes to Neo4j, that is an unauthenticated write path. `AWS_IAM` requires Sigv4 signing using existing AWS credentials, with no extra infrastructure.

## Orphan Cleanup

A `CDKToolkit-neo4jdemo` stack was left in `ROLLBACK_COMPLETE` in us-east-2 during the CDK investigation. Delete it manually if present:

```bash
aws cloudformation delete-stack --region us-east-2 --stack-name CDKToolkit-neo4jdemo
aws cloudformation wait stack-delete-complete --region us-east-2 --stack-name CDKToolkit-neo4jdemo
```
