# Neo4j EE: Public

`neo4j-public.template.yaml` deploys a Neo4j Enterprise cluster in public subnets with an internet-facing Network Load Balancer. Every instance has a public IP. There is no bastion and no SSM tunneling required. Use this topology for proof-of-concept deployments, demos, and evaluation. Production and regulated workloads should use the Private template.

| AWS Resource | What it creates |
|---|---|
| VPC | New VPC with public subnets: one per AZ for a 3-node cluster, one for a single instance |
| Internet Gateway | Outbound internet access; no NAT Gateways needed |
| Internet-facing NLB | Listeners on port 7474 (HTTP) and 7687 (Bolt); distributes connections across cluster nodes |
| EC2 instances | 1 or 3 Neo4j nodes with public IPs; no NAT, no private subnets |
| ASG per node | One Auto Scaling Group per Neo4j node, fixed at `MinSize=MaxSize=DesiredCapacity=1`, for self-healing |
| EBS data volumes | One GP3 volume per node with `DeletionPolicy: Retain`; survives stack deletion |
| Security groups | `NLBSecurityGroup` (AllowedCIDR on 7474/7687 to the NLB); `ExternalSecurityGroup` (NLBSecurityGroup as source on 7474/7687 to the instances); `InternalSecurityGroup` (cluster ports 5000/6000/7000/7688 between cluster members only) |
| CloudWatch | Log group, VPC flow logs, failed-auth alarm, CloudTrail trail |

---

## Operator Guide

### Prerequisites

```bash
aws --version         # AWS CLI v2
```

The IAM role or user needs CloudFormation, EC2, ELB, IAM, SSM, and CloudWatch permissions covering the stack resources.

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
```

`deploy.py` detects your public IP automatically and restricts the security group to `<your-ip>/32`. Pass `--allowed-cidr` to override. The script writes outputs to `.deploy/<stack-name>.txt`.

Stack creation takes 5-10 minutes.

> **Note:** The test runner (`uv run test-neo4j --edition ee`) must execute from the same egress IP used at deploy time, or the security group blocks Bolt and HTTP connections. For CI, pass `--allowed-cidr` with a static egress IP at deploy time.

### Access

Connection details are in the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --region <region> \
  --query 'Stacks[0].Outputs' \
  --output table
```

This returns the NLB DNS name and Bolt URI. Connect directly from your machine. No SSM tunneling required.

- Neo4j Browser: `http://<nlb-dns>:7474`
- Bolt: `neo4j://<nlb-dns>:7687`

The NLB DNS resolves to the public IPs of the EC2 instances. Connections from outside `AllowedCIDR` are dropped at the NLB security group.

### Retrieve the Password

The Neo4j admin password is stored in Secrets Manager as a plain string: the password value itself, not JSON.

```bash
aws secretsmanager get-secret-value \
  --secret-id <password-secret-arn> \
  --query SecretString --output text
```

The secret ARN is in the stack outputs as `Neo4jPasswordSecretArn`.

### Tear Down

```bash
./teardown.sh                  # most recent deployment
./teardown.sh <stack-name>     # specific deployment
```

Deletes the CloudFormation stack, the SSM parameter (local AMI mode only), any cross-region AMI copy, and the `.deploy/<stack-name>.txt` file.

EBS data volumes survive stack deletion by design (`DeletionPolicy: Retain`). `teardown.sh` prints the retained volume IDs. To delete them permanently:

```bash
./teardown.sh --delete-volumes
```

---

## Testing the Deployment

### Connection and Observability

Verify Bolt and HTTP are reachable from your machine using the NLB DNS from the stack outputs. Then run the observability checks:

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

### Functional and Cluster Tests

Run the full test suite against a deployed stack:

```bash
cd ../test_neo4j
uv run test-neo4j --edition ee                     # most recent stack
uv run test-neo4j --edition ee --stack <name>      # specific stack
```

The suite covers connectivity, cluster topology, NLB scheme, volume configuration, security group rules, IMDSv2 enforcement, JDWP absence, and EBS resilience. All 29 functional checks pass on a healthy 3-node public stack.

---

## Architecture

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

### Security Configuration

| Setting | Value | Notes |
|---|---|---|
| `AllowedCIDR` | Required | CIDR allowed to reach ports 7474 and 7687. `0.0.0.0/0` is rejected. `deploy.py` defaults to `<your-public-ip>/32`. |
| NLB security group | Filters external traffic | `AllowedCIDR` on ports 7474 and 7687 to the NLB |
| Instance security group | Sources from NLB SG | Allows both forwarded client traffic and NLB health checks without hardcoding a VPC CIDR |
| IMDSv2 | Enforced | Instance metadata requires session tokens; IMDSv1 requests are rejected |
| JDWP (port 5005) | Disabled | Remote debug port is closed and the JVM debug flag is stripped from `neo4j.conf` at boot |

### NLB Routing

At boot, each cluster node sets two `neo4j.conf` values:

```
server.bolt.advertised_address = <nlb-dns>:7687
dbms.routing.default_router    = SERVER
```

Setting the advertised address to the NLB DNS means every routing table entry points back to the NLB. A driver connecting with `neo4j://` receives a routing table containing only the NLB DNS, sends all subsequent requests through it, and lets Neo4j server-side routing handle write-versus-read direction.

| Access pattern | URI | Notes |
|---|---|---|
| Direct from internet | `neo4j://<nlb-dns>:7687` | |
| Direct node IP (same subnet) | `bolt://<node-ip>:7687` | Bypasses NLB; single node, no failover |

### EBS Persistence

Each node has a dedicated GP3 EBS data volume. `DeletionPolicy: Retain` keeps the volume when the stack is deleted or the ASG replaces an instance. On each new instance launch, UserData resolves the correct NVMe device by matching the EBS volume serial number against `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*` and mounts the volume without reformatting.

### Key Design Decision: Two-Layer Security Group Design

NLB health checks originate from the NLB's private VPC IPs, not from `AllowedCIDR`. If `AllowedCIDR` is applied directly to the instance security group, health check traffic is blocked and all NLB targets fail.

The template solves this with two security groups:
- `Neo4jNLBSecurityGroup` on the NLB: allows `AllowedCIDR` on 7474/7687. Filters external client traffic without hardcoding any VPC CIDR.
- `Neo4jExternalSecurityGroup` on the instances: sources from `Neo4jNLBSecurityGroup` via `SourceSecurityGroupId`. Allows both forwarded client traffic and NLB health checks.

This pattern works for any marketplace deployment without knowing the VPC CIDR at template-authoring time.
