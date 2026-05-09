# Neo4j Private Cluster: Lambda Demo App

The neo4j-ee Private and ExistingVpc templates deploy a cluster in private subnets behind an internal NLB with no public IPs. [`docs/PRIVATE.md`](../docs/PRIVATE.md) covers how a laptop operator connects via SSM port-forwarding. This app shows how an application workload connects to that same cluster from inside the VPC.

Connecting requires three things: attach to the correct VPC and subnets, wire the application's security group for Bolt traffic to the Neo4j NLB and for HTTPS to the VPC interface endpoints, then resolve `AdvertisedDNS` and the password at runtime through those endpoints. The EE stack publishes all the resource IDs an application needs as SSM parameters under `/neo4j-ee/<stack-name>/`.

The VPC contains interface endpoints for SSM, Secrets Manager, and CloudWatch Logs with `PrivateDnsEnabled: true`. Every AWS API call the application makes routes through those endpoint ENIs, and the endpoint security group gates access. An application that is not added to the endpoint security group will hang silently on every AWS API call, including the log writes that would otherwise surface the problem.

This README explains the platform contract the EE stack publishes, the security group wiring required, and the Lambda implementation in this directory.

---

## Architecture

```
Internet
    │
    ▼
Lambda Function URL  (HTTPS, AWS_IAM auth)
    │
    └─ Lambda  (private subnet, Neo4j VPC)
           │  NEO4J_SSM_ADVERTISED_DNS_PATH → /neo4j-ee/<stack>/advertised-dns
           │  NEO4J_SECRET_ARN              → neo4j/<stack>/password
           ▼
    Internal NLB  (neo4j+s://<AdvertisedDNS>:7687)
           │
    ┌──────┴──────┐
    ▼             ▼             ▼
  Neo4j-1      Neo4j-2       Neo4j-3
  (private subnet, each AZ)
```

The Lambda's security group has two egress rules: TCP 7687 to the Neo4j NLB SG for Bolt, and TCP 443 to the VPC interface endpoint SG for SSM, Secrets Manager, and CloudWatch Logs. No traffic leaves the VPC.

---

## Platform Contract

The EE stack publishes a stable set of SSM parameters under `/neo4j-ee/<stack-name>/` that describe everything an application needs to attach itself. `preflight.sh` validates these on every run.

| Parameter | What the app uses it for |
|---|---|
| `/neo4j-ee/<stack>/vpc-id` | Attach Lambda to the correct VPC |
| `/neo4j-ee/<stack>/advertised-dns` | DNS name resolving to the NLB; Lambda connects via `neo4j+s://<advertised-dns>:7687`. The NLB-presented ACM cert SAN must match this name. |
| `/neo4j-ee/<stack>/external-sg-id` | NLB security group used as the egress target on port 7687 for Bolt |
| `/neo4j-ee/<stack>/password-secret-arn` | Import the Neo4j password secret by ARN |
| `/neo4j-ee/<stack>/vpc-endpoint-sg-id` | Add ingress 443 from app SG; add egress 443 to endpoint SG |
| `/neo4j-ee/<stack>/private-subnet-1-id` | Place Lambda in the first private subnet |
| `/neo4j-ee/<stack>/private-subnet-2-id` | Place Lambda in the second private subnet |

The platform owns the infrastructure and publishes IDs; the application looks them up and attaches itself. The platform never needs to know about specific applications.

---

## Security Group Wiring

Each application creates its own security group and establishes two connections.

**Bolt to Neo4j.** The application's security group adds egress TCP 7687 to the NLB security group from `/external-sg-id`. The sample also adds an ingress rule on that NLB security group allowing 7687 from the application security group.

**HTTPS to VPC endpoints.** The application's security group adds egress TCP 443 to `VpcEndpointSecurityGroup` (from `/vpc-endpoint-sg-id`). The application also adds an ingress rule on `VpcEndpointSecurityGroup` allowing 443 from its own security group.

Both connections are required. Without the ingress rule on `VpcEndpointSecurityGroup`, the endpoint SG drops every TCP SYN from the application's ENI before any bytes are exchanged. Because CloudWatch Logs writes take the same path, the function times out with no log output.

This sample establishes both wiring connections in `sample-private-app.template.yaml` using `AWS::EC2::SecurityGroupIngress` resources on the EE stack's security groups. Stack deletion removes those rules automatically.

---

## Lambda Connection Pattern

At cold start the Lambda resolves two values from the platform contract: `AdvertisedDNS` from SSM and the Neo4j password from Secrets Manager. Both calls route through private VPC endpoints.

```python
import os
import boto3
from neo4j import GraphDatabase

ssm = boto3.client("ssm")
sm  = boto3.client("secretsmanager")
_driver = None

def _init_driver():
    advertised_dns = ssm.get_parameter(Name=os.environ["NEO4J_SSM_ADVERTISED_DNS_PATH"])["Parameter"]["Value"]
    password = sm.get_secret_value(SecretId=os.environ["NEO4J_SECRET_ARN"])["SecretString"]
    return GraphDatabase.driver(f"neo4j+s://{advertised_dns}:7687", auth=("neo4j", password))
```

Using `neo4j+s://` fetches a routing table from Neo4j on first connect and validates the NLB-presented ACM certificate against `AdvertisedDNS`. The routing table lists `AdvertisedDNS` as the single endpoint for both writes and reads, because each node sets `server.bolt.advertised_address` to that name. The driver sends all subsequent requests through the NLB, which distributes connections across cluster nodes and lets Neo4j's server-side routing direct writes to the current leader.

The driver is created lazily on first invocation and cached across warm starts. If the cached driver hits an `AuthError` (for example, after a password rotation), the handler closes it, rebuilds a fresh driver, and retries once.

---

## Observability

Three Lambda settings that are easy to skip and painful to diagnose without:

**Log retention.** Set an explicit retention period. The default never-expire accumulates cost silently.

**Structured logging.** JSON log format with `INFO` level makes logs queryable in CloudWatch Logs Insights without custom parsers and carries request IDs automatically.

**X-Ray tracing.** Active tracing covers the full Lambda to SSM to Secrets Manager to Bolt path, including per-segment timings. A missing security group rule shows up as a stalled segment rather than a generic timeout. X-Ray writes go through the Lambda service infrastructure and do not require a VPC endpoint.

---

## Prerequisites

- An existing neo4j-ee Private-mode stack (run `../deploy.py --marketplace --mode Private`)
- Python 3 and pip installed locally
- `AWS_PROFILE` pointing to an account with permissions for CloudFormation, Lambda, IAM, EC2, S3, SSM, and Secrets Manager

---

## Workflow

All scripts run from the `sample-private-app/` directory:

```bash
# Deploy against the most recent EE stack
./deploy-sample-private-app.sh

# Or target a specific EE stack
./deploy-sample-private-app.sh test-ee-1776575131

# Invoke the Lambda
./invoke.sh

# Optional: deploy with --enable-resilience, then run the stop/start resilience test
./validate.sh

# Tear down (always do this BEFORE tearing down the parent EE stack)
./teardown-sample-private-app.sh
```

`deploy-sample-private-app.sh` reads the EE stack's SSM parameters, packages the Lambda, uploads it to a deploy S3 bucket, runs `aws cloudformation deploy`, and writes the Function URL to `/neo4j-sample-private-app/<stack>/function-url` in SSM and `../.deploy/sample-private-app-<ee-stack>.json` locally. It also generates `invoke.sh` in the same directory. Pass `--enable-resilience` only for test deployments that should include the stop/start validation Lambda.

The EE stack's SSM parameters (`/neo4j-ee/<stack>/vpc-id`, `advertised-dns`, `private-subnet-1-id`, `private-subnet-2-id`, `external-sg-id`, `password-secret-arn`) are CloudFormation resources that exist for the lifetime of the EE stack and need no manual management.

### Teardown ordering

Always delete this stack before tearing down the parent EE stack. `sample-private-app.template.yaml` owns two `AWS::EC2::SecurityGroupIngress` resources on the EE stack's security groups: Bolt ingress on the NLB SG and HTTPS ingress on the VPC endpoint SG. If the EE stack is deleted first, those SG rules become orphaned and `DELETE_IN_PROGRESS` stalls.

---

## What the Lambda Returns

```json
{
  "bolt_scheme": "neo4j+s",
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

The Function URL wraps this as `{"statusCode": 200, "headers": {...}, "body": "<json string>"}`. `invoke.sh` pipes the body through `python3 -m json.tool` for readability.

On first invocation, nodes and relationships are created. Subsequent invocations use `MERGE`, so the graph stays idempotent. Several queries confirm distinct cluster properties: `dbms.components()` verifies Enterprise Edition, `dbms.routing.getRoutingTable({}, 'neo4j')` confirms a leader has been elected and the routing table is fully populated, `SHOW SERVERS` reports per-node health, and a `Customer → Account → Transaction → Merchant` traversal returns `graph_sample` to prove the graph is queryable end-to-end.

---

## Resilience Test

`validate.sh` is only usable when the app was deployed with `--enable-resilience`. It calls the second Lambda's Function URL. That Lambda:

1. Calls `CALL dbms.cluster.overview()` over the NLB to find the LEADER and FOLLOWER server UUIDs for the `neo4j` database.
2. Calls `ec2:DescribeInstances` filtered by `tag:StackID = <Neo4j EE stack ARN>` and `tag:Role = neo4j-cluster-node` to list the cluster EC2 instances. The EE ASG propagates its own `StackID` and `Role` tags to launched instances; `aws:cloudformation:stack-name` is only on the ASG itself, not its instances.
3. Maps instance-ID to Neo4j server UUID by running `cat /var/lib/neo4j/data/server_id` on all three instances in parallel via SSM `send-command`.
4. Picks a random follower, runs `systemctl stop neo4j` via SSM, polls `SHOW SERVERS` until that server's `health` is no longer `Available` (expect `Unavailable` within ~10-20s).
5. Runs `systemctl start neo4j` via SSM, polls `SHOW SERVERS` until `health == 'Available'` again (expect ~20-60s for Raft rejoin).
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

The resilience Lambda is test-only and is not deployed by default. When `--enable-resilience` is used, its role has `ssm:SendCommand` on `AWS-RunShellScript` scoped to EC2 instances via `aws:ResourceTag/StackID = <full EE stack ARN>`, so it can issue the fixed stop/start commands only to instances launched by the paired EE stack. `ec2:DescribeInstances` is `*` because the service does not support resource-level authorization, but is read-only. The main invoke Lambda has none of these permissions.

This stack also provisions an `ec2` VPC interface endpoint reusing the EE stack's endpoint SG. The EE stack provides `ssm`, `ssmmessages`, `logs`, and `secretsmanager` endpoints but no `ec2` endpoint, and the resilience Lambda has no internet egress. Without this endpoint, `DescribeInstances` hangs until timeout.

### Lambda timeout

The resilience Lambda is configured with `Timeout: 300` (5 minutes). `validate.sh` uses `curl --max-time 310` so the HTTP call does not cut the function off before it finishes. Function URLs have a hard ceiling of 900s; the 300s budget is a comfortable margin for the stop/start cycle.

---

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

---

## Project Structure

```
sample-private-app/
├── deploy-sample-private-app.sh      # Package Lambda, deploy CFN stack, generate invoke.sh + optional validate.sh
├── teardown-sample-private-app.sh    # Delete CFN stack, S3 zip versions, local files
├── invoke.sh                         # Generated at deploy time (calls the main Lambda)
├── validate.sh                       # Generated at deploy time; requires --enable-resilience
├── sample-private-app.template.yaml  # CloudFormation template (main Lambda plus opt-in resilience Lambda)
└── lambda/
    ├── handler.py                    # lambda_handler (main) + resilience_handler (stop/start a follower)
    └── requirements.txt              # neo4j>=6,<7
```

---

## Bolt TLS

TLS is mandatory in the EE stack. The NLB terminates TLS on 7687 using the customer-supplied ACM cert whose SAN matches AdvertisedDNS, and the target group re-encrypts to a self-signed backend cert generated on each instance.

The Lambda reads AdvertisedDNS from SSM (`<SsmPrefix>/advertised-dns`) and connects via `neo4j+s://<AdvertisedDNS>:7687`. The driver validates the NLB-presented ACM cert against the system trust store, so no certificate file or custom SSL context is needed.

For this to work inside the VPC, AdvertisedDNS must resolve to the NLB. In Private mode, set up a Route 53 private hosted zone with an A or CNAME record pointing AdvertisedDNS at the NLB (or use a public Route 53 record if the operator prefers). The Lambda must be able to resolve AdvertisedDNS via the VPC resolver.

---

## Deploy Bucket

`deploy-sample-private-app.sh` creates an S3 bucket named `neo4j-sample-private-app-deploy-<account>-<region>` with versioning enabled. Object versioning forces Lambda code updates on every deploy without changing the S3 key. `teardown-sample-private-app.sh` deletes all versions of the stack's zip key but leaves the bucket for reuse across stacks.

---

## Key Design Decisions

**Plain CloudFormation, not CDK.** The AWS Organizations SCP in this account blocks `iam:AttachRolePolicy` on CDK's default bootstrap role name pattern, making CDK bootstrap impossible. Plain CloudFormation with `--capabilities CAPABILITY_IAM` is not affected.

**Direct boto3 at cold start, not the Parameters and Secrets Lambda Extension.** The extension adds a region-specific Layer ARN that must be kept current and adds local HTTP proxy overhead. For a demo invoked infrequently, direct boto3 calls are simpler. The extension is the right call for production workloads with high invocation rates where per-call SDK latency matters.

**Driver cached across invocations with auth-rotation fallback.** The Neo4j driver is created lazily on first invocation and reused on warm starts. If the cached driver hits an `AuthError` (for example, after the password secret rotates), the handler closes it, rebuilds a fresh driver, and retries once.

**S3 object versioning forces code updates.** Each `put-object` returns a new `VersionId` passed as `LambdaS3ObjectVersion`. CloudFormation sees the version change and updates the function without rotating the S3 key.

**Function URL auth is `AWS_IAM`.** An unsigned Function URL accepts requests from any caller who knows the URL. Since the Lambda writes to Neo4j, that is an unauthenticated write path. `AWS_IAM` requires Sigv4 signing using existing AWS credentials, with no extra infrastructure.

**Additional AWS API calls need their own VPC endpoints.** If the application calls AWS services beyond SSM, Secrets Manager, and CloudWatch Logs, add a corresponding interface VPC endpoint. The per-endpoint cost is roughly $7/AZ/month; routing is automatic once `PrivateDnsEnabled: true` is set.
