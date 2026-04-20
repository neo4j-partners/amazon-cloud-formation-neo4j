# Building Applications on a Private Neo4j Cluster

A VPC-attached application that wants to query a Private-mode Neo4j cluster faces a specific wiring problem. The cluster is not the hard part — connecting to the NLB on port 7687 is straightforward. The hard part is that the same VPC contains interface VPC endpoints with `PrivateDnsEnabled: true`, which means AWS API hostnames resolve to endpoint ENIs rather than public endpoints. Any call the application makes to SSM, Secrets Manager, or CloudWatch Logs hits those endpoint ENIs — and the endpoint security group gates access to them. An application that is not wired into the endpoint security group hangs silently on every AWS API call, including the log writes that would otherwise explain what went wrong.

This guide explains the architectural contract the Neo4j EE platform publishes, the security group wiring an application must establish to use it, and the reference implementation in `sample-private-app/`.

---

## Architecture

```
Internet
    │
    ▼
Lambda Function URL  (HTTPS, AWS_IAM auth)
    │
    └─ Lambda  (private subnet, Neo4j VPC)
           │  reads /neo4j-ee/<stack>/nlb-dns from SSM
           │  reads neo4j/<stack>/password from Secrets Manager
           ▼
    Internal NLB  (neo4j://<nlb-dns>:7687)
           │
    ┌──────┼──────┐
    ▼      ▼      ▼
 Neo4j-1  Neo4j-2  Neo4j-3
 (private subnet, each AZ)
```

The Lambda's security group has two egress rules: TCP 7687 to the Neo4j external security group for Bolt, and TCP 443 to the VPC endpoint security group for SSM, Secrets Manager, and CloudWatch Logs. No traffic leaves the VPC.

---

## Platform Contract

The EE stack publishes a stable set of SSM parameters under `/neo4j-ee/<stack-name>/` that describe everything an application needs to attach itself:

| Parameter | What the app uses it for |
|---|---|
| `/neo4j-ee/<stack>/vpc-id` | Attach Lambda to the correct VPC |
| `/neo4j-ee/<stack>/nlb-dns` | Bolt connection string: `neo4j://<nlb-dns>:7687` |
| `/neo4j-ee/<stack>/external-sg-id` | Add as egress target on port 7687 (Bolt to Neo4j) |
| `/neo4j-ee/<stack>/password-secret-arn` | Import the Neo4j password secret by ARN |
| `/neo4j-ee/<stack>/vpc-endpoint-sg-id` | Add ingress 443 from app SG; add egress 443 to endpoint SG |
| `/neo4j-ee/<stack>/private-subnet-1-id` | Place Lambda in the first private subnet |
| `/neo4j-ee/<stack>/private-subnet-2-id` | Place Lambda in the second private subnet |

The pattern: the platform owns the infrastructure and publishes IDs; the application looks them up and attaches itself. The platform never needs to know about specific applications.

---

## Security Group Wiring

Each application creates its own purpose-built security group and establishes two connections:

**Bolt to Neo4j.** The application's security group adds egress TCP 7687 to `Neo4jExternalSecurityGroup` (from `/external-sg-id`). `Neo4jExternalSecurityGroup` already has ingress 7687 from the NLB and from `AllowedCIDR`; the application's egress rule is the only change needed on the Neo4j side.

**HTTPS to VPC endpoints.** The application's security group adds egress TCP 443 to `VpcEndpointSecurityGroup` (from `/vpc-endpoint-sg-id`). The application also adds an ingress rule on `VpcEndpointSecurityGroup` allowing 443 from its own security group.

The second connection is the one applications miss. Without it, the endpoint security group drops the TCP SYN from the application's ENI before any application bytes are exchanged. Because CloudWatch Logs writes go the same path, the function times out with no log output.

### Why Not Open the Endpoint Security Group to the Whole VPC CIDR

A blanket `10.0.0.0/16` ingress rule on the endpoint security group gives any workload in the VPC free access to the SSM and Secrets Manager control plane via PrivateLink. Each application's explicit opt-in creates an auditable record of which workloads have access, and removing the application removes its ingress rule cleanly.

### Cross-Stack Security Group Mutation

Because the application stack adds an ingress rule to a security group owned by the EE CloudFormation stack, the CDK import must use `mutable=True`:

```python
endpoint_sg = ec2.SecurityGroup.from_security_group_id(
    self, "Neo4jEndpointSG", endpoint_sg_id, mutable=True,
)
endpoint_sg.add_ingress_rule(lambda_sg, ec2.Port.tcp(443), "Lambda to VPC endpoints")
```

With `mutable=True`, CDK synthesizes an `AWS::EC2::SecurityGroupIngress` resource in the application stack that references the EE-owned security group by ID. This establishes a one-way lifecycle dependency: deleting the application stack removes the ingress rule cleanly. Deleting the EE stack while the application stack still exists fails at the `VpcEndpointSecurityGroup` delete step — tear down the application stack first.

---

## Lambda Connection Pattern

At cold start the Lambda resolves two values from the platform contract: the NLB DNS from SSM and the Neo4j password from Secrets Manager. Both resolve to private endpoints inside the VPC.

```python
import os, ssl
import boto3
from neo4j import GraphDatabase

ssm = boto3.client("ssm")
sm  = boto3.client("secretsmanager")

_CA_BUNDLE = "/var/task/neo4j-ca.crt"
_SSL_CTX = ssl.create_default_context(cafile=_CA_BUNDLE) if os.path.exists(_CA_BUNDLE) else None

def _init_driver():
    nlb_dns  = ssm.get_parameter(Name=os.environ["NEO4J_SSM_NLB_PATH"])["Parameter"]["Value"]
    password = sm.get_secret_value(SecretId=os.environ["NEO4J_SECRET_ARN"])["SecretString"]
    if _SSL_CTX is not None:
        return GraphDatabase.driver(f"neo4j+s://{nlb_dns}:7687", auth=("neo4j", password), ssl_context=_SSL_CTX)
    return GraphDatabase.driver(f"neo4j://{nlb_dns}:7687", auth=("neo4j", password))
```

Using `neo4j://` rather than `bolt://` fetches a routing table from Neo4j on first connect. The routing table lists the NLB DNS as the single endpoint for writers and readers (because each node sets `server.bolt.advertised_address` to the NLB DNS). The driver sends all subsequent requests through the NLB, which distributes connections across cluster nodes and lets Neo4j's server-side routing direct writes to the current leader.

When Bolt TLS is enabled, the connection uses `neo4j+s://` with the self-signed CA bundle staged at `lambda/neo4j-ca.crt`. The Lambda handler detects the presence of that file and switches schemes automatically.

**Direct boto3 at cold start, not the Parameters and Secrets Lambda Extension.** The extension adds a region-specific Layer ARN that must be kept current and adds local HTTP proxy overhead. For an infrequently invoked Lambda, direct boto3 calls are simpler and the round trip to the private endpoint is fast. The extension is the right call for production workloads with high invocation rates where the per-call latency of SDK calls matters.

---

## Observability

Three Lambda settings that are easy to skip and painful to diagnose without:

**`log_retention=ONE_MONTH`.** CDK's default is never expire, which accumulates cost silently.

**`logging_format=JSON` with `application_log_level=INFO`.** Structured logs are queryable in CloudWatch Logs Insights without custom parsers and carry request IDs automatically.

**`tracing=ACTIVE`.** X-Ray traces the full Lambda → SSM → Secrets Manager → Bolt path, including per-segment timings. A missing security group rule shows up as a stalled segment rather than a generic timeout — the same class of network hang this guide is designed to prevent.

X-Ray writes go through the Lambda service infrastructure and do not require a VPC endpoint.

---

## Deploy and Invoke

All commands run from the `sample-private-app/` directory:

```bash
# Deploy against the most recent EE stack
./deploy-sample-private-app.sh

# Or target a specific EE stack
./deploy-sample-private-app.sh test-ee-1776575131

# Invoke the Lambda
./invoke.sh

# Tear down
./teardown-cdk.sh
```

`deploy-sample-private-app.sh` reads the EE stack's SSM parameters, passes them as CDK context, runs `cdk deploy`, writes the Function URL to `/neo4j-cdk/<cdk-stack>/function-url` in SSM, and generates `invoke.sh` in the same directory.

The Lambda Function URL uses `authType: AWS_IAM`. `invoke.sh` signs the request via `curl --aws-sigv4`. To invoke manually:

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

Expected response:

```json
{
  "edition": "enterprise",
  "nodes_created": 12,
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

A `routing_table` with `writers: 1` and `readers: 2` confirms a leader has been elected and the routing table is fully populated. On first invocation the Lambda creates 12 nodes and 9 relationships. Subsequent invocations use `MERGE`, so the graph is idempotent.

---

## Project Structure

```
sample-private-app/
├── deploy-sample-private-app.sh  # Reads SSM params, runs cdk deploy, generates invoke.sh
├── teardown-cdk.sh               # Deletes CDK stack and SSM function-url parameter
├── invoke.sh                     # Generated at deploy time; handles Sigv4 signing
├── app.py                        # CDK entry point
├── cdk.json                      # CDK configuration
├── requirements.txt              # CDK dependencies
├── neo4j_demo/
│   └── neo4j_demo_stack.py       # Lambda, security groups, IAM role, Function URL
└── lambda/
    ├── handler.py                # Lambda handler: connect, merge, check servers, return report
    ├── requirements.txt          # neo4j>=5.0
    └── neo4j-ca.crt              # Staged by deploy.py --tls; absent on plain Bolt deployments
```

---

## Extending This Pattern

**No SSM lookups inside CDK.** `Vpc.from_lookup` requires a concrete VPC ID at synthesis time. Nesting an SSM lookup inside a CDK VPC lookup is fragile across two synth cycles. Resolve all values from AWS before calling `cdk deploy` and pass them as context (`-c vpcId=... -c externalSgId=...`), so synthesis is deterministic.

**Teardown order matters.** The application stack adds an ingress rule to the EE stack's `VpcEndpointSecurityGroup`. CloudFormation cannot delete a security group that has referenced rules in another stack. Always delete the application stack before the EE stack.

**Additional AWS API endpoints.** If the application calls AWS services beyond SSM, Secrets Manager, and CloudWatch Logs, add a corresponding interface VPC endpoint to the EE template (or a separate networking stack). The per-endpoint cost is roughly $7/AZ/month; the routing is automatic once `PrivateDnsEnabled: true` is set.

**Function URL auth is `AWS_IAM`.** An unsigned Function URL accepts requests from any caller who knows the URL. Since the Lambda writes to Neo4j, that is an unauthenticated write path. `AWS_IAM` requires Sigv4 signing using existing AWS credentials, with no extra infrastructure.

**Teardown uses CloudFormation directly.** `cdk destroy` re-synthesizes the app to identify the stack, which requires all original context values. Calling `aws cloudformation delete-stack` directly avoids re-synthesizing with dummy values when the EE stack may already be gone.
