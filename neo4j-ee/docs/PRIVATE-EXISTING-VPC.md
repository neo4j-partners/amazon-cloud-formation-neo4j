# Neo4j EE: Private, Existing VPC

`neo4j-private-existing-vpc.template.yaml` deploys a Neo4j Enterprise cluster into a VPC you supply. The template creates the bastion, NLB, cluster ASGs, EBS volumes, security groups, and SSM contract. It does not create a VPC, subnets, or NAT Gateways. Use this topology when the cluster must live inside an existing network: peered VPC, Transit Gateway, shared services account, or a VPC provisioned by a separate infrastructure team.

| AWS Resource | What it creates |
|---|---|
| Internal NLB | Listeners on port 7474 (HTTP) and 7687 (Bolt); deployed into the subnets you supply |
| EC2 instances | 1 or 3 Neo4j nodes in your private subnets; no public IPs |
| ASG per node | One Auto Scaling Group per Neo4j node, fixed at `MinSize=MaxSize=DesiredCapacity=1`, for self-healing |
| EBS data volumes | One GP3 volume per node with `DeletionPolicy: Retain`; survives stack deletion |
| Operator bastion | `t4g.nano` in your private subnet, not registered as an NLB target; receives SSM sessions for operator access |
| VPC interface endpoints | `ssm`, `ssmmessages`, `logs`, `secretsmanager` with `PrivateDnsEnabled: true`; created when `CreateVpcEndpoints=true` (the default), skipped when `CreateVpcEndpoints=false` |
| Security groups | External SG (AllowedCIDR on 7474/7687 to instances); Internal SG (cluster ports 5000/6000/7000/7688 between members only); Endpoint SG (gating access to the VPC endpoints) |
| SSM parameters | `/neo4j-ee/<stack>/` prefix; publishes VPC ID, NLB DNS, security group IDs, and secret ARN |
| Secrets Manager | Neo4j admin password at `neo4j/<stack>/password` |
| CloudWatch | Log group, VPC flow logs, failed-auth alarm, CloudTrail trail |

The template does **not** create: VPC, subnets, internet gateway, or NAT Gateways. Outbound internet routing is the responsibility of the VPC you supply.

---

## Operator Guide

### Prerequisites

**AWS tooling and Python tooling** are the same as the Private template. See [Prerequisites in PRIVATE.md](PRIVATE.md#prerequisites).

**VPC requirements:**
- Private subnets with outbound internet routing (NAT Gateway, Transit Gateway, or equivalent)
- One subnet for a single-instance deployment; three subnets in different AZs for a three-node cluster
- No pre-existing VPC interface endpoints for `ssm`, `ssmmessages`, `logs`, or `secretsmanager` when `CreateVpcEndpoints=true` (creating duplicates fails the deployment)

**`AllowedCIDR`** defaults to `10.0.0.0/16`. Pass `--allowed-cidr` explicitly if your VPC uses a different CIDR.

### Build

Regenerate the output template after editing any file in `templates/src/`:

```bash
cd neo4j-ee/templates
python build.py
```

Commit both the edited partial and the regenerated `neo4j-private-existing-vpc.template.yaml`.

### Deploy

Pass the VPC and subnet IDs at deploy time:

```bash
cd neo4j-ee

# 1-node
./deploy.py --mode ExistingVpc \
  --number-of-servers 1 \
  --vpc-id vpc-xxxx \
  --subnet-1 subnet-xxxx

# 3-node (three subnets required, one per AZ)
./deploy.py --mode ExistingVpc \
  --vpc-id vpc-xxxx \
  --subnet-1 subnet-a \
  --subnet-2 subnet-b \
  --subnet-3 subnet-c

# With Marketplace AMI
./deploy.py --marketplace --mode ExistingVpc \
  --vpc-id vpc-xxxx \
  --subnet-1 subnet-xxxx

# VPC already has interface endpoints; skip endpoint creation
./deploy.py --mode ExistingVpc \
  --vpc-id vpc-xxxx --subnet-1 subnet-xxxx \
  --create-vpc-endpoints false \
  --existing-endpoint-sg-id sg-xxxx
```

The deploy script writes outputs to `.deploy/<stack-name>.txt`. Stack creation takes 10-20 minutes (includes AMI copy if the region differs from the source AMI region; pin `--region` to the source region to skip the copy).

### Create a Test VPC

For automated testing, `scripts/create-test-vpc.py` provisions a minimal private-networking VPC (`10.42.0.0/16`) and writes all resource IDs to `.deploy/vpc-<ts>.txt`. `deploy.py` reads that file automatically when `--mode ExistingVpc` and no `--vpc-id` is provided:

```bash
# Path A: template creates endpoints (default)
scripts/create-test-vpc.py --region us-east-1
./deploy.py --mode ExistingVpc --number-of-servers 3

# Path B: VPC already has endpoints
scripts/create-test-vpc.py --region us-east-1 --with-endpoints
./deploy.py --mode ExistingVpc --number-of-servers 1 --create-vpc-endpoints false

# Select a specific VPC file when multiple exist
./deploy.py --mode ExistingVpc --vpc-file .deploy/vpc-<ts>.txt
```

### Access, Admin Tools, and Password

Access via bastion and all operator tools (`preflight.sh`, `validate-private`, `admin-shell`, `run-cypher`, `smoke-write.sh`, `browser-tunnel.sh`) are identical to the Private template. See [the Operator Guide in PRIVATE.md](PRIVATE.md#operator-guide) from "Preflight Check" onward.

### Tear Down

Tear down the EE stack, then the test VPC if one was created:

```bash
./teardown.sh --delete-volumes <stack-name>
scripts/teardown-test-vpc.py       # deletes test VPC, NAT gateways, subnets, endpoints, removes vpc-*.txt
```

`teardown-test-vpc.py` defaults to the most recently modified `vpc-*.txt` in `.deploy/`. Pass a VPC deployment name (`vpc-<ts>`) to target a specific one.

Stack deletion removes any `AWS::EC2::SecurityGroupIngress` rules the template added to a pre-existing endpoint SG (`CreateVpcEndpoints=false` path). No manual cleanup is needed.

> **Note:** The template does not create NAT Gateways. The test VPC created by `create-test-vpc.py` does provision NAT Gateways; tear it down promptly after testing.

---

## Testing the Deployment

The full test sequence mirrors the Private template. Two paths exist depending on whether the VPC has pre-existing endpoints.

### Path A: Template Creates Endpoints (CI Gate)

```bash
cd neo4j-ee

# 1. Create test VPC (no endpoints)
scripts/create-test-vpc.py --region us-east-1

# 2. Deploy 3-node cluster (auto-detects vpc-*.txt)
./deploy.py --mode ExistingVpc --number-of-servers 3
STACK=$(ls -t .deploy/test-ee-*.txt | head -1 | xargs basename | sed 's/\.txt$//')

# 3. Preflight (11 checks: stack, bastion, endpoints)
cd validate-private
./scripts/preflight.sh "$STACK"

# 4. Basic cluster validation (8 checks)
uv run validate-private --stack "$STACK"

# 5. Failover suite
uv run validate-private --stack "$STACK" --suite failover

# 6. Resilience suite
uv run validate-private --stack "$STACK" --suite resilience

# 7. Teardown
cd ..
./teardown.sh --delete-volumes "$STACK"
scripts/teardown-test-vpc.py
```

### Path B: Pre-Existing Endpoints

```bash
cd neo4j-ee

# 1. Create test VPC with endpoints
scripts/create-test-vpc.py --region us-east-1 --with-endpoints

# 2. Deploy 1-node cluster (auto-detects VPC file and reads EndpointSgId)
./deploy.py --mode ExistingVpc --number-of-servers 1 --create-vpc-endpoints false
STACK=$(ls -t .deploy/test-ee-*.txt | head -1 | xargs basename | sed 's/\.txt$//')

# 3. Preflight: endpoint reachability confirms the wiring the template added
cd validate-private
./scripts/preflight.sh "$STACK"

# 4. Basic cluster validation (cluster roles: 1 writer for 1-node is PASS)
uv run validate-private --stack "$STACK"

# 5. Teardown (stack deletion removes the SecurityGroupIngress rules)
cd ..
./teardown.sh --delete-volumes "$STACK"
scripts/teardown-test-vpc.py
```

### Observability

```bash
./test-observability.sh                  # most recent deployment
./test-observability.sh <stack-name>     # specific deployment
```

Same five steps as the Private template: CloudWatch agent, log streams, VPC flow logs, failed-auth alarm, and CloudTrail.

---

## Architecture

### Relationship to the Private Template

This template is structurally identical to `neo4j-private.template.yaml`: same operator bastion, same internal NLB, same cluster ASGs, same SSM platform contract. The only difference is that it does not provision any VPC or networking infrastructure. It accepts `VpcId` and `PrivateSubnet1Id/2Id/3Id` and deploys entirely into the caller-supplied network.

The NLB hairpin fix (non-target bastion plus `preserve_client_ip.enabled=false`) applies here exactly as in the Private template. See [Operator Bastion: NLB Hairpin in PRIVATE.md](PRIVATE.md#operator-bastion-nlb-hairpin) for the root cause and two-layer fix.

### VPC Interface Endpoint Design

Two parameters control endpoint creation:

**`CreateVpcEndpoints` (default `true`)**
When `true`, the template creates all four interface endpoints and a dedicated endpoint security group. When `false`, the caller supplies an existing endpoint SG via `ExistingEndpointSgId`. A CloudFormation `Rules` block enforces that `ExistingEndpointSgId` is non-empty when `CreateVpcEndpoints=false`. The deployment fails at parameter validation if it is missing.

Enterprise VPCs typically have a single shared endpoint SG covering all four interface endpoints. Creating duplicate endpoints in a VPC that already has them fails the deployment. This flag prevents that.

**Why a single `CreateVpcEndpoints` flag, not per-service flags**

The original design used two flags (`CreateSSMEndpoint` + `CreateSecretsManagerEndpoint`). That produced four possible states, two of which are half-managed: endpoints split between the template's SG and the customer's SG. A single `vpc-endpoint-sg-id` SSM contract parameter cannot correctly represent both groups. Customers who have pre-existing endpoints virtually always have a shared SG covering all four. The single flag matches the real-world case cleanly.

**Endpoint security group ingress**

Both paths publish a `vpc-endpoint-sg-id` SSM parameter pointing to the correct, functional endpoint SG: the template-created one (Path A) or the caller-supplied one (Path B). Applications follow the same contract in both cases — add their own security group to this SG's ingress on port 443 to reach the endpoints.

The instance and bastion SGs are wired into the endpoint SG at deploy time. In Path B, the template adds `AWS::EC2::SecurityGroupIngress` rules into the pre-existing endpoint SG; stack deletion removes those rules automatically.

### What the Caller's VPC Must Provide

| Requirement | Notes |
|---|---|
| Private subnets with outbound routing | NAT Gateway, Transit Gateway, or Direct Connect; the template provisions none of these |
| One subnet per AZ for a 3-node cluster | Each Neo4j node and its bastion are placed in the subnet passed via `PrivateSubnet1/2/3Id` |
| No duplicate interface endpoints | If `CreateVpcEndpoints=true`, the VPC must not already have `ssm`, `ssmmessages`, `logs`, or `secretsmanager` endpoints; use `CreateVpcEndpoints=false` if it does |
| Matching CIDR in `AllowedCIDR` | Defaults to `10.0.0.0/16`; pass `--allowed-cidr` if your VPC uses a different range |

### Platform Contract

Identical to the Private template. See [Platform Contract in PRIVATE.md](PRIVATE.md#platform-contract) for the full SSM parameter reference.

### Production DNS Alias (BoltAdvertisedDNS)

In production, use a stable customer-owned DNS name in front of the NLB so that certificates are not pinned to the AWS-generated NLB DNS:

1. Create a Route 53 private hosted zone with an A-record alias pointing to the internal NLB, or configure external DNS pointing to the NLB.
2. Obtain a certificate for that name.
3. Push the cert and key to Secrets Manager in the JSON format described in [Bolt TLS in PRIVATE.md](PRIVATE.md#bolt-tls).
4. Set the `BoltAdvertisedDNS` and `BoltCertificateSecretArn` CloudFormation parameters when creating or updating the stack. Pass them via the AWS CloudFormation console or `aws cloudformation create-stack --parameters`.

`server.bolt.advertised_address`, the cert SAN, and the client connect URL will all resolve to the custom DNS name. Certificate rotation does not require reissuing against a changing NLB DNS: update the Secrets Manager secret value and trigger an ASG instance refresh.
