# Neo4j Private Cluster — Lambda Demo App

The neo4j-ee stack deploys its cluster in private subnets behind an internal NLB with no public IPs. [`OPERATOR_GUIDE.md`](../OPERATOR_GUIDE.md) covers how to connect a laptop via SSM port-forwarding. This CDK app answers a different question: how does an application workload connect to that same cluster from inside the VPC?

For the full architecture, security group wiring, and design decisions behind this pattern, see [`APP_GUIDE.md`](../APP_GUIDE.md).

The answer is a Python Lambda in the cluster's private subnets. It connects via `neo4j://` on the internal NLB DNS, creates a small fintech graph, then returns a cluster health report. A Lambda Function URL with `authType: AWS_IAM` exposes it publicly without requiring API Gateway.

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
    Internal NLB  (neo4j://<nlb-dns>:7687)
           │
    ┌──────┴──────┐
    ▼             ▼             ▼
  Neo4j-1      Neo4j-2       Neo4j-3
  (private subnet, each AZ)
```

The Lambda's security group has two egress rules: TCP 7687 to the Neo4j external SG for Bolt, and TCP 443 to anywhere for SSM and Secrets Manager API calls through the VPC's NAT Gateway. The password secret is owned by the EE CloudFormation stack; the Lambda imports it by ARN rather than creating a new one.

## Prerequisites

- An existing neo4j-ee Private-mode stack (run `../deploy.py --marketplace --mode Private`)
- AWS CDK v2 and Python 3 installed locally
- `AWS_PROFILE` pointing to an account with permissions for CloudFormation, Lambda, IAM, EC2, SSM, and Secrets Manager

## Workflow

All scripts run from the `sample-private-app/` directory:

```bash
# Deploy the CDK app against the most recent EE stack
./deploy-sample-private-app.sh

# Or target a specific EE stack
./deploy-sample-private-app.sh test-ee-1776575131

# Invoke the Lambda
./invoke.sh

# Tear down
./teardown-cdk.sh
```

`deploy-sample-private-app.sh` reads the EE stack's SSM parameters, passes them as CDK context, runs `cdk deploy`, and writes the Function URL to `/neo4j-cdk/<cdk-stack>/function-url` in SSM and `../.deploy/cdk-<cdk-stack>.json` locally. It also generates `invoke.sh` in the same directory.

The EE stack's SSM parameters (`/neo4j-ee/<stack>/vpc-id`, `nlb-dns`, `private-subnet-1-id`, `private-subnet-2-id`, `external-sg-id`, `password-secret-arn`) are CloudFormation resources — they exist for the lifetime of the EE stack and need no manual management.

## What the Lambda Returns

```json
{
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
  --name "/neo4j-cdk/<cdk-stack>/function-url" \
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
├── deploy-sample-private-app.sh  # Deploy CDK stack; generates invoke.sh
├── teardown-cdk.sh               # Delete CDK stack and SSM parameter
├── invoke.sh                     # Generated at deploy time
├── app.py                        # CDK entry point; stack name from cdkStackName context
├── cdk.json                      # CDK configuration
├── requirements.txt              # CDK dependencies
├── neo4j_demo/
│   └── neo4j_demo_stack.py       # Lambda, SG, IAM role, Function URL
└── lambda/
    ├── handler.py                # Lambda handler (6-step: connect, merge, check, report)
    └── requirements.txt          # neo4j>=5.0
```

## Key Design Decisions

**No SSM lookups inside CDK.** `Vpc.from_lookup` requires a concrete VPC ID at synthesis time. Nesting an SSM lookup inside a VPC lookup is fragile across two CDK synth cycles. `deploy-sample-private-app.sh` resolves all values from AWS before calling `cdk deploy` and passes them as context (`-c vpcId=... -c externalSgId=...`), so synthesis is deterministic.

**Direct boto3 at cold start, not the Parameters and Secrets Lambda Extension.** The extension adds a region-specific Layer ARN that must be kept current and adds local HTTP proxy overhead. For a demo invoked infrequently, direct boto3 calls are simpler and clearer. The extension is the right call for production workloads with high invocation rates.

**Function URL auth is `AWS_IAM`.** An unsigned Function URL accepts requests from any caller who knows the URL. Since the Lambda writes to Neo4j, that is an unauthenticated write path. `AWS_IAM` requires Sigv4 signing using existing AWS credentials, with no extra infrastructure.

**Teardown uses CloudFormation directly.** `cdk destroy` re-synthesizes the app to identify the stack, which requires all original context values. Calling `aws cloudformation delete-stack` instead avoids re-synthesizing with dummy values when the EE stack may already be gone.
