# Neo4j Private Cluster: Lambda Demo App

`sample-private-app.template.yaml` deploys a Lambda inside the Neo4j EE VPC that connects to Neo4j over Bolt through the internal NLB. Use it as both a runnable smoke test and a reference implementation for building private application clients.

- **What it deploys:** a Python Lambda in the EE stack's private subnets, exposed via a Function URL with `AWS_IAM` auth
- **What it requires:** an existing neo4j-ee Private or ExistingVpc stack
- **What it demonstrates:** SSM parameter discovery, Secrets Manager password retrieval, security group wiring to the NLB and VPC interface endpoints, topology-aware Bolt URI selection, and TLS trust handling for public, imported, private, and self-signed ACM certificates
- **Optional:** `--enable-resilience` adds a second Lambda that stops/starts a follower to validate cluster failover

[`docs/PRIVATE.md`](../docs/PRIVATE.md) covers operator access from a laptop via SSM port-forwarding. This README covers application access from inside the VPC and the platform contract an application team should consume.

## Contents

- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [Workflow](#workflow)
  - [Teardown Ordering](#teardown-ordering)
- [Architecture](#architecture)
  - [Diagram](#diagram)
  - [Platform Contract](#platform-contract)
  - [Security Group Wiring](#security-group-wiring)
  - [Bolt TLS](#bolt-tls)
- [Lambda Connection Pattern](#lambda-connection-pattern)
- [Building Your Own Client](#building-your-own-client)
  - [Client Checklist](#client-checklist)
  - [Connection Mode Matrix](#connection-mode-matrix)
  - [Python Driver Example](#python-driver-example)
  - [Other Neo4j Drivers](#other-neo4j-drivers)
  - [Packaging a Custom CA](#packaging-a-custom-ca)
  - [Adapting the Sample](#adapting-the-sample)
  - [Troubleshooting Clients](#troubleshooting-clients)
- [What the Lambda Returns](#what-the-lambda-returns)
- [Resilience Test](#resilience-test)
  - [IAM Scoping](#iam-scoping)
  - [Lambda Timeout](#lambda-timeout)
- [Observability](#observability)
- [Invoking from a Laptop](#invoking-from-a-laptop)
- [Key Design Decisions](#key-design-decisions)
- [Project Structure](#project-structure)

---

## Quick Start

### Prerequisites

- An existing neo4j-ee Private or ExistingVpc stack
- VPC DNS resolution for the EE stack's `AdvertisedDNS` name to the internal NLB. Private-mode stacks deployed by `deploy.py` create this private alias by default with `CreatePrivateDns=true`; ExistingVpc stacks must either opt in with `--create-private-dns` or provide customer-managed DNS.
- `uv` installed locally
- AWS credentials available through the normal AWS SDK/CLI credential chain, such as `AWS_PROFILE`, with permissions for CloudFormation, Lambda, IAM, EC2, S3, SSM, Secrets Manager, and ACM read APIs
- For imported or private ACM certificates, permission to call `acm:DescribeCertificate` and `acm:GetCertificate` so the deployer can package the trust bundle

### Workflow

All scripts run from the `sample-private-app/` directory:

```bash
# Deploy against the most recent EE stack
uv run deploy-sample-private-app.py

# Or target a specific EE stack
uv run deploy-sample-private-app.py test-ee-1776575131

# Invoke the Lambda
./invoke.sh

# Optional: deploy with --enable-resilience, then run the stop/start resilience test
./validate.sh

# Tear down (always do this BEFORE tearing down the parent EE stack)
./teardown-sample-private-app.sh
```

`deploy-sample-private-app.py` reads the EE stack outputs and SSM parameters, chooses the correct Bolt scheme and trust mode, packages the Lambda, uploads it to a deploy S3 bucket, deploys the CloudFormation stack with boto3, and writes the Function URL to `/neo4j-sample-private-app/<stack>/function-url` in SSM and `../.deploy/sample-private-app-<ee-stack>.json` locally. It also generates `invoke.sh` and `validate.sh` in the same directory. Pass `--enable-resilience` only for test deployments that should include the stop/start validation Lambda.

### Teardown Ordering

Always delete this stack before tearing down the parent EE stack. `sample-private-app.template.yaml` owns two `AWS::EC2::SecurityGroupIngress` resources on the EE stack's security groups: Bolt ingress on the NLB SG and HTTPS ingress on the VPC endpoint SG. If the EE stack is deleted first, those SG rules become orphaned and `DELETE_IN_PROGRESS` stalls.

---

## Architecture

### Diagram

```
Internet
    │
    ▼
Lambda Function URL  (HTTPS, AWS_IAM auth)
    │
    └─ Lambda  (private subnet, Neo4j VPC)
           │  NEO4J_SSM_ADVERTISED_DNS_PATH → /neo4j-ee/<stack>/advertised-dns
           │  NEO4J_SECRET_ARN              → neo4j/<stack>/password
           │  NEO4J_BOLT_SCHEME             → bolt, bolt+s, neo4j, neo4j+s, or +ssc variant
           │  NEO4J_TRUSTED_CA_CERT_FILE    → optional bundled CA PEM
           ▼
    Internal NLB  (<scheme>://<AdvertisedDNS>:7687)
           │
    ┌──────┴──────┐
    ▼             ▼             ▼
  Neo4j-1      Neo4j-2       Neo4j-3
  (private subnet, each AZ)
```

The Lambda's security group has two egress rules: TCP 7687 to the Neo4j NLB SG for Bolt, and TCP 443 to the VPC interface endpoint SG for SSM, Secrets Manager, and CloudWatch Logs. Neo4j and AWS API calls stay on private VPC paths; the Function URL ingress is handled by the Lambda service.

### Platform Contract

The EE stack publishes a stable set of SSM parameters under `/neo4j-ee/<stack-name>/` that describe everything an application needs to attach itself. Application stacks should read these values at deployment time, not hard-code VPC IDs, subnet IDs, security group IDs, DNS names, or secret ARNs.

| Parameter | What the app uses it for |
|---|---|
| `/neo4j-ee/<stack>/vpc-id` | Attach Lambda to the correct VPC |
| `/neo4j-ee/<stack>/advertised-dns` | DNS name resolving to the NLB from inside the VPC. The NLB-presented ACM cert SAN must match this name. |
| `/neo4j-ee/<stack>/nlb-dns` | Internal NLB DNS name. Useful for diagnostics and DNS records, but client drivers should normally connect to `advertised-dns` so TLS hostname validation matches. |
| `/neo4j-ee/<stack>/external-sg-id` | NLB security group used as the egress target on port 7687 for Bolt |
| `/neo4j-ee/<stack>/password-secret-arn` | Import the Neo4j password secret by ARN |
| `/neo4j-ee/<stack>/vpc-endpoint-sg-id` | Add ingress 443 from app SG; add egress 443 to endpoint SG |
| `/neo4j-ee/<stack>/private-subnet-1-id` | Place Lambda in the first private subnet |
| `/neo4j-ee/<stack>/private-subnet-2-id` | Place Lambda in the second private subnet for clustered EE stacks; omitted when `NumberOfServers=1` |
| `/neo4j-ee/<stack>/region` | Region for clients that need explicit AWS SDK configuration |
| `/neo4j-ee/<stack>/stack-name` | Parent EE stack name for tagging, logs, and diagnostics |

The platform owns the infrastructure and publishes IDs; the application looks them up and attaches itself. The platform never needs to know about specific applications.

### Security Group Wiring

Each application creates its own security group and establishes two connections.

- **Bolt to Neo4j**
  - Egress on the app SG: TCP 7687 to the NLB SG (from `/external-sg-id`)
  - Ingress on the NLB SG: TCP 7687 from the app SG
- **HTTPS to VPC endpoints**
  - Egress on the app SG: TCP 443 to `VpcEndpointSecurityGroup` (from `/vpc-endpoint-sg-id`)
  - Ingress on `VpcEndpointSecurityGroup`: TCP 443 from the app SG

Both connections are required. Without the ingress rule on `VpcEndpointSecurityGroup`, the endpoint SG drops every TCP SYN from the application's ENI before any bytes are exchanged. Because CloudWatch Logs writes take the same path, the function times out with no log output.

This sample establishes both wiring connections in `sample-private-app.template.yaml` using `AWS::EC2::SecurityGroupIngress` resources on the EE stack's security groups. Stack deletion removes those rules automatically.

For non-Lambda clients, keep the same pattern:

- Put the workload in private subnets that can resolve `AdvertisedDNS`
- Attach an application-owned security group to the workload
- Allow egress from the application SG to the NLB SG on TCP 7687
- Add ingress on the NLB SG from the application SG on TCP 7687
- Allow HTTPS egress to the VPC endpoint SG if the workload reads SSM, Secrets Manager, or other AWS APIs without NAT
- Add ingress on the VPC endpoint SG from the application SG on TCP 443

### Bolt TLS

- **TLS is mandatory.** The NLB terminates TLS on 7687 using the customer-supplied ACM cert whose SAN matches `AdvertisedDNS`; the target group re-encrypts to a self-signed backend cert generated on each instance
- **Trust is selected at deploy time.** Public ACM certificates use the Lambda runtime's system CA store. ACM `IMPORTED` and `PRIVATE` certificates are fetched from ACM and packaged as `neo4j-ca.pem`; the Lambda then configures the Neo4j driver with `TrustCustomCAs`
- **Driver mode follows topology.** Single-server stacks use direct Bolt (`bolt+s://` for system trust, `bolt://` with a custom CA bundle). Multi-server stacks use routed Neo4j (`neo4j+s://` for system trust, `neo4j://` with a custom CA bundle)
- **Self-signed test certificates are local-test only.** Local stacks created with `certificate.py --self-signed` are detected from the EE deploy outputs and use `+ssc` schemes only when the cert is not handled as an ACM imported/private certificate
- **DNS must resolve inside the VPC.** The sample app consumes the EE stack's `AdvertisedDNS`; it does not create or repair DNS. Private-mode stacks deployed by `deploy.py` create the private DNS alias by default. For ExistingVpc or customer-managed DNS, ensure `AdvertisedDNS` resolves from the Lambda subnets to the internal NLB through your VPC resolver, private hosted zone, or enterprise DNS forwarding
- **Do not connect to the raw NLB DNS name from application code.** The certificate is issued for `AdvertisedDNS`, not the generated NLB hostname. Use the NLB DNS only as the target of the private DNS record.

---

## Lambda Connection Pattern

At cold start the Lambda resolves two values from the platform contract: `AdvertisedDNS` from SSM and the Neo4j password from Secrets Manager. Both calls route through private VPC endpoints.

```python
import os
import boto3
from neo4j import GraphDatabase, TrustCustomCAs

ssm = boto3.client("ssm")
sm  = boto3.client("secretsmanager")
_driver = None

def _init_driver():
    advertised_dns = ssm.get_parameter(Name=os.environ["NEO4J_SSM_ADVERTISED_DNS_PATH"])["Parameter"]["Value"]
    password = sm.get_secret_value(SecretId=os.environ["NEO4J_SECRET_ARN"])["SecretString"]
    bolt_scheme = os.environ.get("NEO4J_BOLT_SCHEME", "neo4j+s")
    driver_config = {}
    ca_file = os.environ.get("NEO4J_TRUSTED_CA_CERT_FILE", "").strip()
    if ca_file:
        driver_config["encrypted"] = True
        driver_config["trusted_certificates"] = TrustCustomCAs(ca_file)
    return GraphDatabase.driver(
        f"{bolt_scheme}://{advertised_dns}:7687",
        auth=("neo4j", password),
        **driver_config,
    )
```

Using `neo4j+s://` or `neo4j://` fetches a routing table from Neo4j on first connect. The routing table lists `AdvertisedDNS` as the endpoint for both writes and reads, because each node sets `server.bolt.advertised_address` to that name. The driver sends subsequent requests through the NLB, which distributes connections across cluster nodes and lets Neo4j's server-side routing direct writes to the current leader. Single-server stacks use direct `bolt` mode and skip routing-table validation.

The driver is created lazily on first invocation and cached across warm starts. If the cached driver hits an `AuthError` (for example, after a password rotation), the handler closes it, rebuilds a fresh driver, and retries once.

---

## Building Your Own Client

Use this sample as the minimum contract for any private Neo4j client running in AWS. The same shape works for Lambda, ECS, EKS, EC2, Batch, Glue jobs in a VPC, or a service in a peered VPC that can resolve and route to the internal NLB.

### Client Checklist

1. Read the EE stack's deployment output or know the parent stack name.
2. Read platform parameters from `/neo4j-ee/<stack>/`:
   `advertised-dns`, `vpc-id`, `external-sg-id`, `password-secret-arn`,
   `vpc-endpoint-sg-id`, and the private subnet IDs you need.
3. Place the client in private subnets with DNS resolution enabled.
4. Create an application-owned security group.
5. Wire Bolt access: application SG egress to the NLB SG on TCP 7687, and NLB SG ingress from the application SG on TCP 7687.
6. Wire AWS API access if the client reads SSM or Secrets Manager privately: application SG egress to the endpoint SG on TCP 443, and endpoint SG ingress from the application SG on TCP 443.
7. Retrieve the Neo4j password from the Secrets Manager ARN published by the EE stack.
8. Connect to `AdvertisedDNS`, not to the raw NLB DNS name.
9. Select the driver URI scheme from the topology and certificate trust mode.
10. Cache the driver or connection pool across requests, then close it during process shutdown.

### Connection Mode Matrix

The deployer chooses this automatically for the Lambda sample. Other clients should follow the same rules.

| EE topology | ACM certificate trust | Driver URI | Extra driver config |
|---|---|---|---|
| Single server | Public ACM certificate | `bolt+s://<AdvertisedDNS>:7687` | None |
| Single server | ACM `IMPORTED` or `PRIVATE` certificate | `bolt://<AdvertisedDNS>:7687` | `encrypted=True`, trust the packaged CA bundle |
| Single server | Self-signed skip-validation test | `bolt+ssc://<AdvertisedDNS>:7687` | None |
| Multi-server | Public ACM certificate | `neo4j+s://<AdvertisedDNS>:7687` | None |
| Multi-server | ACM `IMPORTED` or `PRIVATE` certificate | `neo4j://<AdvertisedDNS>:7687` | `encrypted=True`, trust the packaged CA bundle |
| Multi-server | Self-signed skip-validation test | `neo4j+ssc://<AdvertisedDNS>:7687` | None |

Use `neo4j://` or `neo4j+s://` only when you want driver-side routing, which is the right choice for clustered deployments. Use `bolt://` or `bolt+s://` for direct single-server deployments. On a one-server stack, routed mode can fail with `Unable to retrieve routing information`; direct Bolt avoids that routing-table dependency.

### Python Driver Example

This is the reusable connection pattern from the Lambda sample. The same pattern works in any Python service with `boto3` and `neo4j>=6,<7`.

```python
import os

import boto3
from neo4j import GraphDatabase, TrustCustomCAs


ssm = boto3.client("ssm")
secrets = boto3.client("secretsmanager")


def build_driver(stack_name: str):
    prefix = f"/neo4j-ee/{stack_name}"
    advertised_dns = ssm.get_parameter(
        Name=f"{prefix}/advertised-dns"
    )["Parameter"]["Value"]
    secret_arn = ssm.get_parameter(
        Name=f"{prefix}/password-secret-arn"
    )["Parameter"]["Value"]
    password = secrets.get_secret_value(SecretId=secret_arn)["SecretString"]

    # Set these from deployment metadata, not from request input.
    bolt_scheme = os.environ["NEO4J_BOLT_SCHEME"]
    trusted_ca_file = os.environ.get("NEO4J_TRUSTED_CA_CERT_FILE", "").strip()

    driver_config = {}
    if trusted_ca_file:
        driver_config["encrypted"] = True
        driver_config["trusted_certificates"] = TrustCustomCAs(trusted_ca_file)

    return GraphDatabase.driver(
        f"{bolt_scheme}://{advertised_dns}:7687",
        auth=("neo4j", password),
        **driver_config,
    )
```

For a Lambda, create the driver lazily outside the handler path and reuse it for warm invocations. For ECS, EKS, EC2, or long-running services, create one driver per process and close it during shutdown. Do not create a new driver for every query.

### Other Neo4j Drivers

The AWS platform contract and URI selection rules are language-independent. Java, JavaScript, .NET, Go, and other official Neo4j drivers need the same four inputs:

- URI: `<scheme>://<AdvertisedDNS>:7687`
- Username: `neo4j`
- Password: Secrets Manager value from `/neo4j-ee/<stack>/password-secret-arn`
- Trust mode: system trust for public ACM certs, custom CA bundle for ACM imported/private certs, or `+ssc` only for local skip-validation tests

For public ACM certificates, use the secure URI scheme directly (`bolt+s` or `neo4j+s`) and the driver's default trust store. For imported or private certificates, use the base URI scheme (`bolt` or `neo4j`), explicitly enable encryption, and configure the driver to trust the packaged CA bundle. Keep hostname verification enabled and connect to `AdvertisedDNS`.

### Packaging a Custom CA

When ACM reports the certificate type as `IMPORTED` or `PRIVATE`, the deployer calls `acm:GetCertificate`, writes the returned certificate chain to `lambda/neo4j-ca.pem`, includes it in the Lambda zip, and removes the temporary file from the working tree after packaging.

Applications that are not using this deployer need an equivalent trust bundle:

- Fetch the certificate chain from ACM during deployment, or obtain the issuing CA bundle from your PKI process
- Package the PEM file with the application image or deployment artifact
- Use the base URI scheme (`bolt://` or `neo4j://`) plus encrypted driver configuration and the custom CA bundle
- Keep hostname validation enabled by connecting to `AdvertisedDNS`

Avoid `+ssc` outside local test stacks. It encrypts traffic but skips certificate authority validation.

### Adapting the Sample

To build a real client from this sample:

- Keep `sample-private-app.template.yaml` as the infrastructure reference for SG rules, IAM permissions, Function URLs, log groups, and VPC placement
- Replace `_MERGE_FINTECH` and the readback query in `lambda/handler.py` with your application workflow
- Keep the SSM and Secrets Manager lookup pattern unless your platform injects equivalent values through another controlled deployment mechanism
- Keep the driver cache and `AuthError` reset path so password rotation can recover on a warm runtime
- Add only the AWS API endpoints your application actually calls. The base app needs SSM, Secrets Manager, and CloudWatch Logs through the EE stack's endpoint SG
- For production, put a real API front door, auth layer, or private integration in front of the workload. The Function URL here is for a minimal sample and uses `AWS_IAM`

### Troubleshooting Clients

| Symptom | Likely cause | What to check |
|---|---|---|
| `Unable to retrieve routing information` | A single-server stack is using `neo4j+s://` or `neo4j://` | Use direct `bolt+s://` or `bolt://` for single-server stacks |
| TLS certificate verification failure | Client trusts system CAs but the ACM cert is imported/private/self-issued | Package the CA bundle and use `TrustCustomCAs`, or use a public ACM certificate |
| Hostname mismatch | Client connected to the raw NLB DNS name | Connect to `AdvertisedDNS`; map that name to the internal NLB |
| Lambda times out with little or no log output | Missing endpoint SG ingress or app SG HTTPS egress | Check TCP 443 rules between app SG and `vpc-endpoint-sg-id` |
| Bolt connection timeout | Missing NLB SG ingress or app SG Bolt egress | Check TCP 7687 rules between app SG and `external-sg-id` |
| `AccessDenied` reading password or SSM params | Application role lacks platform contract permissions | Allow `ssm:GetParameter` under `/neo4j-ee/<stack>/*` and `secretsmanager:GetSecretValue` on the published secret ARN |

---

## What the Lambda Returns

```json
{
  "bolt_scheme": "neo4j+s",
  "trusted_ca": false,
  "edition": "enterprise",
  "nodes_created": 12,
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

The handler returns this through the Lambda Function URL response body. `invoke.sh` pipes that body through `python3 -m json.tool` for readability.

On first invocation, nodes and relationships are created. Subsequent invocations use `MERGE`, so the graph stays idempotent. Several queries confirm distinct cluster properties: `dbms.components()` verifies Enterprise Edition, `SHOW SERVERS` reports per-node health, and a `Customer → Account → Transaction → Merchant` traversal returns `graph_sample` to prove the graph is queryable end-to-end. Routed cluster deployments also run `dbms.routing.getRoutingTable({}, 'neo4j')` to confirm routing is populated.

---

## Resilience Test

`validate.sh` is only usable when the app was deployed with `--enable-resilience`. It calls the second Lambda's Function URL, which:

1. Calls `SHOW DATABASE neo4j YIELD serverID, writer` over the NLB to find the LEADER and FOLLOWER server UUIDs for the `neo4j` database.
2. Calls `ec2:DescribeInstances` filtered by `tag:StackID = <Neo4j EE stack ARN>` and `tag:Role = neo4j-cluster-node` to list the cluster EC2 instances. The EE ASG propagates its own `StackID` and `Role` tags to launched instances; `aws:cloudformation:stack-name` is only on the ASG itself, not its instances.
3. Maps instance-ID to Neo4j server UUID by invoking the sample stack's fixed read-server-id SSM document on all three instances in parallel.
4. Picks a random follower, invokes the sample stack's fixed stop-Neo4j SSM document, then polls `SHOW SERVERS` until that server's `health` is no longer `Available` (expect `Unavailable` within ~10-20s).
5. Invokes the sample stack's fixed start-Neo4j SSM document, then polls `SHOW SERVERS` until `health == 'Available'` again (expect ~20-60s for Raft rejoin).
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

### IAM Scoping

The resilience Lambda is test-only and is not deployed by default. When `--enable-resilience` is used, this stack creates three constrained SSM command documents: read the Neo4j server ID, stop Neo4j, and start Neo4j. The resilience role can run only those stack-owned documents against EC2 instances tagged with `aws:ResourceTag/StackID = <full EE stack ARN>`. It does not receive permission to run the AWS-managed `AWS-RunShellScript` document or pass arbitrary shell commands. `ec2:DescribeInstances` is `*` because the service does not support resource-level authorization, but is read-only. The main invoke Lambda has none of these permissions.

Production accounts should additionally restrict who can update the resilience Lambda code, pass its role, or invoke its Function URL. Those controls belong in customer or organization IAM policy because the sample app cannot safely deny every legitimate deployment principal.

This stack also provisions an `ec2` VPC interface endpoint reusing the EE stack's endpoint SG. The EE stack provides `ssm`, `ssmmessages`, `logs`, and `secretsmanager` endpoints but no `ec2` API endpoint, and the resilience Lambda has no internet egress. Without this endpoint, `DescribeInstances` hangs until timeout.

### Lambda Timeout

The resilience Lambda is configured with `Timeout: 300` (5 minutes). `validate.sh` uses `curl --max-time 310` so the HTTP call does not cut the function off before it finishes. Function URLs have a hard ceiling of 900s; the 300s budget is a comfortable margin for the stop/start cycle.

---

## Observability

Three Lambda settings that are easy to skip and painful to diagnose without:

- **Log retention.** Set an explicit retention period. The default never-expire accumulates cost silently
- **Structured logging.** JSON log format with `INFO` level makes logs queryable in CloudWatch Logs Insights without custom parsers and carries request IDs automatically
- **X-Ray tracing.** Active tracing covers the full Lambda → SSM → Secrets Manager → Bolt path, including per-segment timings. A missing security group rule shows up as a stalled segment rather than a generic timeout. X-Ray writes go through the Lambda service infrastructure and do not require a VPC endpoint

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

## Key Design Decisions

- **Plain CloudFormation, not CDK.** The AWS Organizations SCP in this account blocks `iam:AttachRolePolicy` on CDK's default bootstrap role name pattern, making CDK bootstrap impossible. Plain CloudFormation with `--capabilities CAPABILITY_IAM` is not affected
- **Direct boto3 at cold start, not the Parameters and Secrets Lambda Extension.** The extension adds a region-specific Layer ARN that must be kept current and adds local HTTP proxy overhead. For a demo invoked infrequently, direct boto3 calls are simpler. The extension is the right call for production workloads with high invocation rates where per-call SDK latency matters
- **Driver cached across invocations with auth-rotation fallback.** The Neo4j driver is created lazily on first invocation and reused on warm starts. If the cached driver hits an `AuthError` (for example, after the password secret rotates), the handler closes it, rebuilds a fresh driver, and retries once
- **S3 object versioning forces code updates.** `deploy-sample-private-app.py` creates an S3 bucket named `neo4j-sample-private-app-deploy-<account>-<region>` with versioning enabled. Each `put-object` returns a new `VersionId` passed as `LambdaS3ObjectVersion`. CloudFormation sees the version change and updates the function without rotating the S3 key. `teardown-sample-private-app.sh` deletes all versions of the stack's zip key but leaves the bucket for reuse across stacks
- **Function URL auth is `AWS_IAM`.** An unsigned Function URL accepts requests from any caller who knows the URL. Since the Lambda writes to Neo4j, that is an unauthenticated write path. `AWS_IAM` requires Sigv4 signing using existing AWS credentials, with no extra infrastructure
- **Additional AWS API calls need their own VPC endpoints.** If the application calls AWS services beyond SSM, Secrets Manager, and CloudWatch Logs, add a corresponding interface VPC endpoint. The per-endpoint cost is roughly $7/AZ/month; routing is automatic once `PrivateDnsEnabled: true` is set

---

## Project Structure

```
sample-private-app/
├── deploy-sample-private-app.py      # Package Lambda, deploy CFN stack, generate invoke.sh + optional validate.sh
├── teardown-sample-private-app.sh    # Delete CFN stack, S3 zip versions, local files
├── invoke.sh                         # Generated at deploy time (calls the main Lambda)
├── validate.sh                       # Generated at deploy time; requires --enable-resilience
├── sample-private-app.template.yaml  # CloudFormation template (main Lambda plus opt-in resilience Lambda)
└── lambda/
    ├── handler.py                    # lambda_handler (main) + resilience_handler (stop/start a follower)
    └── requirements.txt              # neo4j>=6,<7
```

The EE stack's SSM parameters (`/neo4j-ee/<stack>/vpc-id`, `advertised-dns`, `private-subnet-1-id`, `external-sg-id`, `password-secret-arn`, `vpc-endpoint-sg-id`, plus `private-subnet-2-id` for clustered stacks) are CloudFormation resources that exist for the lifetime of the EE stack and need no manual management.
