# Neo4j Enterprise Edition — AWS Marketplace

CloudFormation template and tooling for the Neo4j Enterprise Edition AWS Marketplace listing. Supports single-instance and three-node cluster deployments fronted by a Network Load Balancer.

## Quick Start — CLI Deployment

All scripts use the `marketplace` AWS CLI profile. Export it once so every command picks it up:

```bash
export AWS_PROFILE=marketplace
```

### 1. Deploy the Stack

There are two AMI modes depending on what you're testing.

**Marketplace mode** — validates what a live customer receives. No AMI file needed:

```bash
./deploy.sh --marketplace                                                           # t3.medium, 3 nodes, random region
./deploy.sh --marketplace r8i                                                       # memory optimized (r8i.xlarge)
./deploy.sh --marketplace --number-of-servers 1                                     # single instance
./deploy.sh --marketplace --region eu-west-1                                        # specific region
./deploy.sh --marketplace r8i --region us-east-2 --number-of-servers 3
./deploy.sh --marketplace --alert-email you@example.com                             # enable CloudWatch alarm emails
```

**Local AMI mode** — tests a newly built AMI before it is published to the Marketplace. Build the AMI first, then deploy:

```bash
./marketplace/create-ami.sh          # builds AMI, writes ID to marketplace/ami-id.txt
./marketplace/test-ami.sh            # verifies SSH hardening and OS (no SSH key needed)
```

Then deploy using that AMI:

```bash
./deploy.sh                                                            # t3.medium, 3 nodes, random region
./deploy.sh r8i                                                        # memory optimized (r8i.xlarge)
./deploy.sh --number-of-servers 1                                      # single instance
./deploy.sh --region eu-west-1                                         # specific region (AMI auto-copied)
./deploy.sh r8i --region us-east-2 --number-of-servers 3
./deploy.sh --alert-email you@example.com                              # enable CloudWatch alarm emails
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

### 4. Tear Down

```bash
./teardown.sh                  # tears down the most recent deployment
./teardown.sh <stack-name>     # tears down a specific deployment
```

Deletes the CloudFormation stack, the SSM parameter created in local AMI mode, any cross-region AMI copy, and removes the deployment file from `.deploy/`. In `--marketplace` mode only the stack and output file are deleted (no SSM parameter or copied AMI to clean up).

## What Gets Deployed

**Three-node cluster** (`NumberOfServers=3`, the default):
- VPC with three public subnets, one per Availability Zone
- Network Load Balancer (TCP, internet-facing) across all three subnets
- Three EC2 instances forming a Causal Cluster with Raft consensus
- External security group allowing inbound on 7474 (Browser/HTTP) and 7687 (Bolt) from `AllowedCIDR`
- Internal security group restricting cluster ports (6000, 7000, 7688, and others) to cluster members only

**Single instance** (`NumberOfServers=1`):
- VPC with a single public subnet
- Network Load Balancer in that subnet
- One EC2 instance (no clustering; useful for dev/test)

The NLB DNS name is the stable public endpoint in both configurations. Bolt client routing is handled by the NLB — the Neo4j driver connects to port 7687 on the NLB and the cluster handles request routing internally.

**Security configuration:**

| Setting | Default | Notes |
|---|---|---|
| `AllowedCIDR` | `0.0.0.0/0` | CIDR allowed to reach ports 7474 and 7687. Restrict to a VPN or known range for production. |
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
