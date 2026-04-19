# Neo4j Enterprise Edition — AWS Marketplace

CloudFormation template and tooling for the Neo4j Enterprise Edition AWS Marketplace listing. Supports single-instance and three-node cluster deployments fronted by a Network Load Balancer.

## Quick Start — CLI Deployment

All scripts read `AWS_PROFILE` from the environment and fall back to the `default` profile if it is not set. Set it once before running any commands:

```bash
export AWS_PROFILE=<your-profile>   # omit entirely to use your default AWS profile
```

> **Marketplace publishing scripts only** (`marketplace/create-ami.sh`, `marketplace/test-ami.sh`): these must run against the `neo4j-marketplace` AWS account (account `385155106615`). Set `AWS_PROFILE=marketplace` before running them. All other scripts (`deploy.sh`, `teardown.sh`, `test-observability.sh`) work with any account that has CloudFormation, SSM, EC2, and IAM permissions.

### 1. Deploy the Stack

There are two AMI modes depending on what you're testing.

**Marketplace mode** — validates what a live customer receives. The template's published Marketplace AMI is used directly. No local AMI file needed:

```bash
./deploy.sh --marketplace                                                           # t3.medium, 3 nodes, random region, Private mode
./deploy.sh --marketplace r8i                                                       # memory optimized (r8i.xlarge)
./deploy.sh --marketplace --number-of-servers 1                                     # single instance
./deploy.sh --marketplace --region eu-west-1                                        # specific region
./deploy.sh --marketplace r8i --region us-east-2 --number-of-servers 3
./deploy.sh --marketplace --alert-email you@example.com                             # enable CloudWatch alarm emails
./deploy.sh --marketplace --mode Public                                             # internet-facing NLB (opt-in)
```

**Local AMI mode** — tests a newly built AMI before it is published to the Marketplace. Requires the `neo4j-marketplace` account. Build and verify the AMI first:

```bash
AWS_PROFILE=marketplace ./marketplace/create-ami.sh     # builds AMI, writes ID to marketplace/ami-id.txt
AWS_PROFILE=marketplace ./marketplace/test-ami.sh       # verifies SSH hardening and OS (no SSH key needed)
```

Then deploy using that AMI (switch back to your test account profile):

```bash
./deploy.sh                                                            # t3.medium, 3 nodes, random region, Private mode
./deploy.sh r8i                                                        # memory optimized (r8i.xlarge)
./deploy.sh --number-of-servers 1                                      # single instance
./deploy.sh --region eu-west-1                                         # specific region (AMI auto-copied)
./deploy.sh r8i --region us-east-2 --number-of-servers 3
./deploy.sh --alert-email you@example.com                              # enable CloudWatch alarm emails
./deploy.sh --mode Public                                              # internet-facing NLB (opt-in)
```

In local AMI mode the script creates a temporary SSM parameter for the AMI ID and copies the AMI cross-region if needed. Cross-region copies can take 10-20+ minutes — use `--region us-east-1` to skip the copy.

When `--alert-email` is provided, AWS sends a confirmation email to that address after the stack is created. Click the link in that email to activate the SNS subscription before CloudWatch alarm notifications will be delivered.

Multiple deployments can coexist — each gets its own output file in `.deploy/`.

To look up connection details for a deployed stack directly from CloudFormation:

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --region <region> \
  --query 'Stacks[0].Outputs' \
  --output table
```

This returns the NLB DNS name, Bolt URI, and username.

### 2. Test the Stack

```bash
cd test_neo4j
uv run test-neo4j --edition ee                                    # tests the most recent EE deployment
uv run test-neo4j --edition ee --stack <stack-name>               # tests a specific deployment
uv run test-neo4j --edition ee --simple                           # connectivity checks only
uv run test-neo4j --edition ee --simple --infra-security          # connectivity + security config checks
uv run test-neo4j --edition ee --infra-security                   # full mode + security config checks
```

The test suite reads from `neo4j-ee/.deploy/` (most recently modified file by default) and runs two levels of testing:

**Simple mode** (`--simple`) — connectivity + Neo4j configuration:
1. **HTTP API** — GET the discovery endpoint, verify `neo4j_version` is present
2. **Authentication** — POST a Cypher statement with Basic Auth, expect HTTP 200
3. **Bolt connectivity** — connect via the Neo4j driver and execute `RETURN 1`
4. **Neo4j server status** — verify Enterprise Edition via `dbms.components()`
5. **Listen address** — confirm bound to `0.0.0.0`
6. **Memory configuration** — verify heap and page cache are set
7. **Data directory** — confirm `/data` (the persistent EBS mount)

**Full mode** (default) — simple mode + infrastructure validation:
8. **CloudFormation stack status** — verify `CREATE_COMPLETE`
9. **Security group ports** — verify 7474 and 7687 are open

**`--infra-security`** (optional, combinable with either mode) — verifies the network hardening and instance security configuration against the live AWS resources:
10. **External SG ingress CIDR** — both ports match the `AllowedCIDR` stack parameter
11. **Port 5005 absent** — JDWP remote debug port is not open in the internal security group
12. **Internal SG self-reference** — cluster port ingress rules source from the internal SG only
13. **IMDSv2 enforced** — launch template requires session tokens for instance metadata
14. **JDWP absent from neo4j.conf** — verified on a running instance via SSM Run Command

See `TESTING_V2.md` for a full description of each check and the one remaining manual verification step (CloudWatch log streams).

Cluster resilience tests (node failure, leader election) are not yet implemented.

### 3. Test Observability

`test-observability.sh` verifies the Phase 1 observability components that the CloudFormation template provisions: CloudWatch agent, application log streams, VPC flow logs, failed-auth alarm, and CloudTrail.

```bash
./test-observability.sh                                  # all steps, most recent deployment
./test-observability.sh <stack-name>                     # all steps, specific stack
./test-observability.sh --step <name>                    # single step, most recent deployment
./test-observability.sh <stack-name> --step <name>       # single step, specific stack
```

Valid step names:

| Name | What it checks |
|---|---|
| `cloudwatch` | CloudWatch agent active on all nodes (via SSM) |
| `logs` | Application log group exists with the expected stream count |
| `flowlogs` | VPC flow log group exists and has ENI streams |
| `alarm` | Failed-auth alarm transitions to ALARM after 12 bad login attempts |
| `cloudtrail` | A multi-region CloudTrail trail exists and is logging |

The `alarm` step takes up to 7 minutes (5-minute CloudWatch evaluation window). All other steps complete in under a minute. SNS email delivery is flagged as a manual step in the summary — see `TESTING_GUIDE.md` for instructions.

### 4. Connect to a Private Deployment

Private mode (the default) places instances in private subnets with no public IP and an internal NLB. Public mode places instances in public subnets with an internet-facing NLB — useful for demos and development.

#### Driver URI scheme and cluster routing

Neo4j drivers support two URI schemes with different connection semantics:

- **`bolt://`** — connects directly to the specified host and port. No routing table is fetched. All requests go to that single host.
- **`neo4j://`** — uses the Bolt routing protocol. The driver fetches a routing table on first connect, listing writers, readers, and routers. Subsequent requests are distributed across cluster members.

**How the template configures routing**

At boot each cluster node sets two `neo4j.conf` values:

```
server.bolt.advertised_address = <nlb-dns>:7687
dbms.routing.default_router    = SERVER
```

`server.bolt.advertised_address` controls the address this node advertises in routing tables — set to the NLB DNS rather than the node's own private IP. `dbms.routing.default_router=SERVER` tells the node to return a one-entry routing table (the NLB) instead of the full list of cluster member IPs. Any driver connecting with `neo4j://` will receive a routing table containing the NLB DNS name and will send all subsequent requests back through the NLB, which distributes across nodes and lets Neo4j server-side routing handle write vs. read direction internally.

**URI scheme by access pattern**

| Access pattern | Recommended URI | Notes |
|---|---|---|
| Same VPC | `neo4j://<nlb-dns>:7687` | Routing table returns NLB DNS; driver stays on NLB; full cluster failover |
| Peered VPC / Transit Gateway | `neo4j://<nlb-dns>:7687` | NLB DNS resolves to private IPs reachable through the peering route |
| SSM tunnel | `bolt://localhost:7687` | Skips routing table; simple and reliable for operator access |
| SSM tunnel + routing scheme | `neo4j://localhost:7687` with custom resolver | Routing table returns NLB DNS, which resolves to private IPs not routable from the laptop; fails without a custom resolver (see below) |
| Direct node IP (same subnet) | `bolt://<node-ip>:7687` | Bypasses NLB; single node only, no failover — see production patterns below |

**`neo4j://` through an SSM tunnel requires a custom resolver**

Via SSM, the driver connects to `localhost:7687`. The server returns a routing table with the NLB DNS name (e.g., `internal-xxxx.elb.amazonaws.com:7687`). The driver tries to open new connections to that address, which resolves to private IPs inside the VPC — not routable from the operator's laptop. Subsequent requests fail.

The simplest fix is `bolt://localhost:7687` for SSM access. If `neo4j://` is required (for example, a CI runner that must exercise cluster routing), implement a custom resolver that maps the NLB DNS back to `localhost`:

```python
# Python driver — custom resolver for SSM tunnel
from neo4j import GraphDatabase

def resolver(address):
    return [("localhost", 7687)]

driver = GraphDatabase.driver(
    "neo4j://localhost:7687",
    auth=("neo4j", password),
    resolver=resolver
)
```

The custom resolver pattern is available in all official Neo4j drivers.

**References:** [Leadership, routing, and load balancing](https://neo4j.com/docs/operations-manual/current/clustering/setup/routing/) · [Configure network connectors — `server.bolt.advertised_address`](https://neo4j.com/docs/operations-manual/current/configuration/connectors/)

#### From an operator workstation (SSM port-forward)

For interactive access from a laptop or CI runner, use AWS Systems Manager Session Manager port-forwarding — no bastion host or VPN required.

**Prerequisite:** install the Session Manager Plugin alongside the AWS CLI:

```bash
# macOS
brew install --cask session-manager-plugin

# or download from AWS:
# https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
```

The test suite (`uv run test-neo4j`) opens the tunnels automatically. To connect manually, look up the instance ID and NLB DNS from the stack outputs, then:

```bash
# HTTP (Neo4j Browser) on localhost:7474
INSTANCE_ID=$(aws cloudformation describe-stack-resource \
  --stack-name <stack-name> --region <region> \
  --logical-resource-id Neo4jAutoScalingGroup \
  --query StackResourceDetail.PhysicalResourceId --output text | \
  xargs -I{} aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names {} --region <region> \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text)

NLB_DNS=$(aws cloudformation describe-stacks \
  --stack-name <stack-name> --region <region> \
  --query 'Stacks[0].Outputs[?OutputKey==`Neo4jInternalDNS`].OutputValue' \
  --output text)

aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${NLB_DNS},portNumber=7474,localPortNumber=7474" \
  --region <region> &

aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${NLB_DNS},portNumber=7687,localPortNumber=7687" \
  --region <region> &

# Then open http://localhost:7474 in a browser
# or connect bolt: bolt://localhost:7687
```

The stack also outputs ready-to-copy `Neo4jSSMHTTPCommand` and `Neo4jSSMBoltCommand` values with the NLB DNS already substituted — only the instance ID needs to be filled in.

> **Note:** Connection strings generated inside Neo4j Browser (the "Connect URL" field and copy-paste URIs) will show the internal NLB DNS hostname rather than `localhost`. Substitute `localhost` for the hostname to connect through the open tunnel.

#### From application workloads (production patterns)

Application tiers inside AWS reach the internal NLB directly without SSM tunnels. AWS Network Load Balancers support connections from clients over VPC peering, AWS managed VPN, Direct Connect, and third-party VPN solutions.

**Same VPC** — an application running in the same VPC connects to the NLB's internal DNS name on port 7687 (Bolt) or 7474 (HTTP). Set `AllowedCIDR` to `10.0.0.0/16` (the VPC CIDR) at stack launch — no additional security group changes are needed for in-VPC clients.

**VPC Peering / Transit Gateway** — an application in a spoke VPC reaches the NLB's private IP addresses through the peering or TGW route. Two prerequisites: (1) a route in the spoke VPC's route table pointing the Neo4j VPC CIDR at the peering connection or TGW attachment, and (2) `AllowedCIDR` must be updated at stack launch to include the spoke VPC's CIDR (e.g. `10.1.0.0/16`). The NLB DNS resolves directly to private IPs; no additional DNS configuration is required on the peering connection.

**Within the same subnet** — an application in the same subnet can connect directly to individual Neo4j node IPs on port 7687, bypassing the NLB. Use `bolt://<node-ip>:7687`; see [Driver URI scheme and cluster routing](#driver-uri-scheme-and-cluster-routing) for why `neo4j://` should not be used with a direct node IP.

### 5. Tear Down

```bash
./teardown.sh                  # tears down the most recent deployment
./teardown.sh <stack-name>     # tears down a specific deployment
```

> **Note:** Private mode provisions NAT Gateways (1 for single-instance, 3 for cluster), which incur hourly charges. Tear down promptly after testing.

Deletes the CloudFormation stack, the SSM parameter created in local AMI mode, any cross-region AMI copy, and removes the deployment file from `.deploy/`. In `--marketplace` mode only the stack and output file are deleted (no SSM parameter or copied AMI to clean up).

## What Gets Deployed

The `DeploymentMode` parameter (default: `Private`) controls network placement.

### Private mode (default)

Instances have no public IP and no direct internet exposure. NAT Gateways provide outbound-only internet access (for package updates, etc.). Access is via SSM Session Manager port-forwarding.

**Three-node cluster** (`NumberOfServers=3`):
- VPC with three public subnets (NAT Gateways) and three private subnets (EC2 instances), one pair per AZ
- Internal Network Load Balancer across the three private subnets
- Three NAT Gateways (one per AZ) for cluster-member outbound traffic
- Three EC2 instances in private subnets forming a Causal Cluster with Raft consensus
- External security group allowing inbound on 7474 and 7687 from `AllowedCIDR`
- Internal security group restricting cluster ports (5000, 6000, 7000, 7688, and others) to cluster members only

**Single instance** (`NumberOfServers=1`):
- VPC with one public subnet (NAT Gateway) and one private subnet (EC2 instance)
- Internal Network Load Balancer in the private subnet
- One NAT Gateway for outbound traffic
- One EC2 instance in a private subnet

### Public mode (`--mode Public`)

Instances receive public IP addresses and the NLB is internet-facing. Use for development or when a VPN/private network is not available.

**Three-node cluster** (`NumberOfServers=3`):
- VPC with three public subnets, one per Availability Zone
- Internet-facing Network Load Balancer across all three subnets
- Three EC2 instances with public IPs forming a Causal Cluster with Raft consensus
- External security group allowing inbound on 7474 (Browser/HTTP) and 7687 (Bolt) from `AllowedCIDR`
- Internal security group restricting cluster ports to cluster members only

**Single instance** (`NumberOfServers=1`):
- VPC with a single public subnet
- Internet-facing Network Load Balancer in that subnet
- One EC2 instance with a public IP

### Common to both modes

The NLB DNS name is the stable endpoint in all configurations. The Neo4j driver connects to port 7687 on the NLB and the cluster handles request routing internally. In Private mode, connect via an SSM port-forward tunnel — the test suite handles this automatically.

**Security configuration:**

| Setting | Default | Notes |
|---|---|---|
| `DeploymentMode` | `Private` | `Private`: instances in private subnets, internal NLB, NAT Gateways. `Public`: public IPs, internet-facing NLB. |
| `AllowedCIDR` | *(required)* | CIDR allowed to reach ports 7474 and 7687. Private mode: enter `10.0.0.0/16`. Public mode: enter the CIDR of the clients that should reach the NLB. `0.0.0.0/0` is not accepted. |
| IMDSv2 | enforced | Instance metadata requires session tokens; IMDSv1 requests are rejected. |
| JDWP (port 5005) | disabled | Remote debug port is closed and the JVM debug flag is stripped from `neo4j.conf` at boot. |
| Internal cluster ports | self-referencing | Ports 5000, 6000, 7000, 7688, and others are reachable only from other cluster members. |

## Files

| File | Purpose |
|---|---|
| `neo4j.template.yaml` | CloudFormation template |
| `deploy.sh` | Deploy helper — creates stack, waits, writes outputs to `.deploy/` |
| `teardown.sh` | Deletes the stack, SSM parameter, copied AMI, and deployment file |
| `test-observability.sh` | Automated observability checks (CloudWatch, logs, flow logs, alarm, CloudTrail) |
| `TESTING_V2.md` | Testing guide for network hardening and security configuration verification |
| `security.md` | Security analysis, known gaps, and phased remediation plan |
| `marketplace/` | AMI build and test scripts, Marketplace publishing instructions |
| `marketplace/create-ami.sh` | Automated AMI build — launches instance, runs hardening, creates AMI, writes ID to `ami-id.txt` |
| `marketplace/test-ami.sh` | SSM-based AMI verification — checks SSH hardening and OS (no SSH key required) |
| `marketplace/build.sh` | Hardening script run on the instance (also embedded in `create-ami.sh` UserData) |
| `marketplace/ami-id.txt` | AMI ID from last build (gitignored) |
| `.deploy/` | Deployment output files — one per stack (gitignored) |

Test tooling lives in `../test_neo4j/` and is shared with the CE edition.
