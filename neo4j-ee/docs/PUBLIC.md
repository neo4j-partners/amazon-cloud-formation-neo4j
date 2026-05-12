# Neo4j EE: Public

`neo4j-public.template.yaml` deploys a Neo4j Enterprise cluster in public subnets with an internet-facing Network Load Balancer.

- **What it deploys:** Neo4j EE cluster (1 or 3 nodes) in public subnets behind an internet-facing NLB
- **Public exposure:** every instance has a public IP; client traffic gated by `AllowedCIDR` at the NLB security group
- **Operator access:** direct from your machine — no bastion, no SSM tunneling
- **When to use:** proof-of-concept, demos, evaluation. Production and regulated workloads should use the [Private template](PRIVATE.md)

> **Marketplace operator** (deployed from AWS Marketplace, running stack):
> Start with [Prerequisites](#prerequisites) and the [Operator Guide](#operator-guide) below.
>
> **Template developer** (working on the templates, deploying from source):
> Start with [Local Deployment and Testing](#local-deployment-and-testing).
> The [Operator Guide](#operator-guide) applies once your stack is running.

## Contents

- [Operator Guide](#operator-guide)
  - [Prerequisites](#prerequisites)
  - [Access](#access)
  - [Retrieve the Password](#retrieve-the-password)
  - [Observability Checks](#observability-checks)
- [Architecture](#architecture)
  - [Network Topology](#network-topology)
  - [AWS Resources Created](#aws-resources-created)
  - [Security Configuration](#security-configuration)
  - [NLB Routing](#nlb-routing)
  - [EBS Persistence](#ebs-persistence)
  - [Two-Layer Security Group Design](#two-layer-security-group-design)
- [Local Deployment and Testing](#local-deployment-and-testing)
  - [Build](#build)
  - [Deploy](#deploy)
  - [Functional and Cluster Tests](#functional-and-cluster-tests)
  - [Tear Down](#tear-down)

---

## Operator Guide

Applies to any running public stack, whether deployed from the Marketplace or from source.

### Prerequisites

**AWS tooling**

```bash
aws --version         # AWS CLI v2
```

**IAM permissions**

These are the minimum permissions the operator's local IAM principal (user or assumed role) needs to run the tools in this guide. Each permission corresponds to API calls made from the operator's machine. The cluster nodes use a separate IAM role scoped to what they need at boot.

| Permission | Resource | Used by |
|---|---|---|
| `cloudformation:DescribeStacks` | The stack ARN | `deploy.py` (reads stack outputs), observability and teardown scripts |
| `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` | `neo4j/<stack-name>/password` | Retrieving the Neo4j admin password |
| `ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:DescribeInstanceInformation` | The cluster EC2 instances | `test-observability.sh` (checks CloudWatch agent via SSM Run Command) |

### Access

Connect directly from your machine — no SSM tunneling required.

- **Neo4j Browser:** `http://<NLB DNS>:7474`
- **Bolt:** `neo4j://<NLB DNS>:7687`
- **Ingress filter:** connections from outside `AllowedCIDR` are dropped at the NLB security group

Connection details are in the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --region <region> \
  --query 'Stacks[0].Outputs' \
  --output table
```

### Retrieve the Password

The Neo4j admin password is stored in Secrets Manager at `neo4j/<stack-name>/password` as a plain string: the password value itself, not JSON. The secret ARN is in the stack outputs as `Neo4jPasswordSecretArn`.

```bash
aws secretsmanager get-secret-value \
  --secret-id <password-secret-arn> \
  --query SecretString --output text

# Or use the ready-to-run command from the stack outputs:
aws cloudformation describe-stacks \
  --stack-name <stack-name> --region <region> \
  --query 'Stacks[0].Outputs[?OutputKey==`Neo4jPasswordRetrieveCommand`].OutputValue' \
  --output text | bash
```

### Observability Checks

Verify CloudWatch agent, application logs, VPC flow logs, failed-auth alarm, and CloudTrail:

```bash
./test-observability.sh                  # most recent deployment
./test-observability.sh <stack-name>     # specific deployment
./test-observability.sh --step <name>    # single step
```

| Step | What it checks | Typical duration |
|---|---|---|
| `cloudwatch` | CloudWatch agent active on all nodes (via SSM Run Command) | <1 min |
| `logs` | Application log group exists with the expected stream count | <1 min |
| `flowlogs` | VPC flow log group exists and has ENI streams | <1 min |
| `alarm` | Failed-auth alarm transitions to ALARM after 12 bad login attempts | ~7 min |
| `cloudtrail` | A multi-region CloudTrail trail exists and is logging | <1 min |

---

## Architecture

![Neo4j EE Public Architecture](images/neo4j-public-architecture.png)

### Network Topology

Three-node cluster:
- VPC with three public subnets, one per AZ
- Internet-facing NLB distributing traffic across all three subnets
- Three EC2 instances with public IPs, no NAT Gateways, no private subnets
- Internal security group restricting cluster ports (5000, 6000, 7000, 7688) to cluster members only

Single-instance:
- VPC with one public subnet
- Internet-facing NLB in that subnet
- One EC2 instance with a public IP

### AWS Resources Created

| AWS Resource | What it creates |
|---|---|
| VPC | New VPC with public subnets: one per AZ for a 3-node cluster, one for a single instance |
| Internet Gateway | Outbound internet access; no NAT Gateways needed |
| Internet-facing NLB | Listeners on 7474 (HTTP Browser) and 7687 (Bolt) |
| EC2 instances | 1 or 3 Neo4j nodes with public IPs; no NAT, no private subnets |
| ASG per node | One Auto Scaling Group per Neo4j node, fixed at `MinSize=MaxSize=DesiredCapacity=1`, for self-healing |
| EBS data volumes | One GP3 volume per node with `DeletionPolicy: Retain`; survives stack deletion |
| Security groups | `NLBSecurityGroup` (AllowedCIDR on Browser and Bolt ports to the NLB); `ExternalSecurityGroup` (NLBSecurityGroup as source on Browser and Bolt ports to the instances); `InternalSecurityGroup` (cluster ports 5000/6000/7000/7688 between cluster members only) |
| Secrets Manager | Neo4j admin password at `neo4j/<stack>/password` |
| CloudWatch | Log group, VPC flow logs, failed-auth alarm, CloudTrail trail |

### Security Configuration

| Setting | Value | Notes |
|---|---|---|
| `AllowedCIDR` | Required | CIDR allowed to reach Browser and Bolt ports. `0.0.0.0/0` is rejected. `deploy.py` defaults to `<your-public-ip>/32`. |
| NLB security group | Filters external traffic | `AllowedCIDR` on 7474/7687 |
| Instance security group | Sources from NLB SG | Allows both forwarded client traffic and NLB health checks without hardcoding a VPC CIDR |
| IMDSv2 | Enforced | Instance metadata requires session tokens; IMDSv1 requests are rejected |
| JDWP (port 5005) | Disabled | Remote debug port is closed and the JVM debug flag is stripped from `neo4j.conf` at boot |
| Bolt TLS | Optional test flow | `deploy.py --tls` can enable self-signed Bolt TLS on 7687 for local testing. Browser remains HTTP on 7474. |

### NLB Routing

At boot, each cluster node advertises the NLB DNS name for Bolt routing and keeps Neo4j Browser on HTTP port 7474. Server-side routing directs writes to the leader and reads to followers automatically.

| Access pattern | URI | Notes |
|---|---|---|
| Direct from internet | `neo4j://<NLB DNS>:7687` | No customer domain is required; use for public evaluation only. |
| Direct node IP (same subnet) | `neo4j://<node-ip>:7687` | Bypasses NLB; single node, no failover. |

Public stacks do not manage public DNS records.

### EBS Persistence

Each node has a dedicated GP3 EBS data volume. `DeletionPolicy: Retain` keeps the volume when the stack is deleted or the ASG replaces an instance. On each new instance launch, UserData resolves the correct NVMe device by matching the EBS volume serial number against `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*` and mounts the volume without reformatting.

### Two-Layer Security Group Design

> **Why two SGs?** NLB health checks originate from the NLB's private VPC IPs, not from `AllowedCIDR`. Applying `AllowedCIDR` directly to the instance SG blocks health checks and fails all NLB targets.

- **`Neo4jNLBSecurityGroup` (on the NLB):** allows `AllowedCIDR` on Browser/Bolt ports — filters external client traffic without hardcoding any VPC CIDR
- **`Neo4jExternalSecurityGroup` (on the instances):** sources from `Neo4jNLBSecurityGroup` via `SourceSecurityGroupId` — allows both forwarded client traffic and NLB health checks

This pattern works for any marketplace deployment without knowing the VPC CIDR at template-authoring time.

---

## Local Deployment and Testing

### Build

Regenerate the output template after editing any file in `templates/src/`:

```bash
cd neo4j-ee/templates
python build.py
```

Commit both the edited partial and the regenerated `neo4j-public.template.yaml`.

### Deploy

```bash
cd neo4j-ee

# 3-node cluster, t3.medium, random region
./deploy.py --mode Public

# Single instance
./deploy.py --mode Public --number-of-servers 1

# Memory-optimized instance
./deploy.py --mode Public r8i.xlarge

# Pin region (avoids 10-20 min AMI copy)
./deploy.py --mode Public --region us-east-1

# Use the published Marketplace AMI
./deploy.py --mode Public --marketplace

# Enable CloudWatch alarm email notifications
./deploy.py --mode Public --alert-email you@example.com

# Optional self-signed Bolt TLS test flow
./deploy.py --mode Public --tls
```

`deploy.py` detects your public IP automatically and restricts the security group to `<your-ip>/32`. Pass `--allowed-cidr` to override. The script writes outputs to `.deploy/<stack-name>.txt`.

Stack creation takes 5-10 minutes.

> **Note:** The test runner (`uv run test-neo4j --edition ee`) must execute from the same egress IP used at deploy time, or the security group blocks Bolt and HTTP connections. For CI, pass `--allowed-cidr` with a static egress IP at deploy time.

### Functional and Cluster Tests

Run the full test suite against a deployed stack:

```bash
cd ../test_neo4j
uv run test-neo4j --edition ee                     # most recent stack
uv run test-neo4j --edition ee --stack <name>      # specific stack
```

The suite covers connectivity, cluster topology, NLB scheme, volume configuration, security group rules, IMDSv2 enforcement, JDWP absence, and EBS resilience. All 29 functional checks pass on a healthy 3-node public stack.

### Tear Down

```bash
./teardown.sh <stack-name>
./teardown.sh --delete-volumes <stack-name>   # also permanently deletes EBS volumes
```
