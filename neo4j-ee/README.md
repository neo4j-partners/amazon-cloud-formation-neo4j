# Neo4j Enterprise Edition — AWS Marketplace

CloudFormation templates and tooling for the Neo4j Enterprise Edition AWS Marketplace listing. Supports single-instance and three-node cluster deployments fronted by a Network Load Balancer across three topologies: private new VPC, public new VPC, and private existing VPC.

---

## Commands Overview

All scripts read `AWS_PROFILE` from the environment and fall back to the `default` profile if it is not set:

```bash
export AWS_PROFILE=<your-profile>   # omit to use your default AWS profile
```

> **Marketplace publishing scripts only** (`marketplace/create-ami.sh`, `marketplace/test-ami.sh`): these must run against the `neo4j-marketplace` AWS account (account `385155106615`). Set `AWS_PROFILE=marketplace` before running them. All other scripts (`deploy.py`, `teardown.sh`, `test-observability.sh`) work with any account that has CloudFormation, SSM, EC2, and IAM permissions.

### 1. Deploy the Stack

Two AMI modes depending on what you are testing.

**Marketplace mode** — uses the published Marketplace AMI directly. No local AMI file needed:

```bash
./deploy.py --marketplace                                  # t3.medium, 3 nodes, random region, Private mode
./deploy.py --marketplace r8i                              # memory optimized (r8i.xlarge)
./deploy.py --marketplace --number-of-servers 1            # single instance
./deploy.py --marketplace --region eu-west-1               # specific region
./deploy.py --marketplace --mode Public                    # internet-facing NLB (opt-in)
./deploy.py --marketplace --alert-email you@example.com    # enable CloudWatch alarm emails
./deploy.py --marketplace --mode ExistingVpc --vpc-id vpc-xxxx --subnet-1 subnet-xxxx                                              # existing VPC, 1-node
./deploy.py --marketplace --mode ExistingVpc --number-of-servers 3 --vpc-id vpc-xxxx --subnet-1 subnet-a --subnet-2 subnet-b --subnet-3 subnet-c  # existing VPC, 3-node
./deploy.py --marketplace --mode ExistingVpc --vpc-file .deploy/vpc-<ts>.txt                                                                       # existing VPC, read IDs from file
```

**Local AMI mode** — tests a newly built AMI before it is published. Build and verify the AMI first (requires the `neo4j-marketplace` account):

```bash
AWS_PROFILE=marketplace ./marketplace/create-ami.sh   # builds AMI, writes ID to marketplace/ami-id.txt
AWS_PROFILE=marketplace ./marketplace/test-ami.sh     # verifies SSH hardening and OS
```

Then deploy using that AMI:

```bash
./deploy.py                                    # t3.medium, 3 nodes, random region, Private mode
./deploy.py r8i                                # memory optimized (r8i.xlarge)
./deploy.py --number-of-servers 1              # single instance
./deploy.py --region eu-west-1                 # specific region (AMI auto-copied)
./deploy.py --mode Public                      # internet-facing NLB (opt-in)
./deploy.py --alert-email you@example.com      # enable CloudWatch alarm emails
./deploy.py --mode ExistingVpc --vpc-id vpc-xxxx --subnet-1 subnet-xxxx                                              # existing VPC, 1-node
./deploy.py --mode ExistingVpc --number-of-servers 3 --vpc-id vpc-xxxx --subnet-1 subnet-a --subnet-2 subnet-b --subnet-3 subnet-c  # existing VPC, 3-node
./deploy.py --mode ExistingVpc --vpc-file .deploy/vpc-<ts>.txt                                                                       # existing VPC, read IDs from file
```

In local AMI mode, the script creates a temporary SSM parameter for the AMI ID and copies the AMI cross-region if needed. Cross-region copies take 10-20+ minutes — use `--region us-east-1` to skip the copy.

When `--alert-email` is provided, AWS sends a confirmation email after stack creation. Click the link to activate the SNS subscription before CloudWatch alarm notifications will be delivered.

Multiple deployments can coexist — each gets its own output file in `.deploy/`.

### 2. Look Up Connection Details

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --region <region> \
  --query 'Stacks[0].Outputs' \
  --output table
```

Returns the NLB DNS name, Bolt URI, and username.

### 3. Test Observability

`test-observability.sh` verifies the observability components the CloudFormation template provisions: CloudWatch agent, application log streams, VPC flow logs, failed-auth alarm, and CloudTrail.

```bash
./test-observability.sh                                  # all steps, most recent deployment
./test-observability.sh <stack-name>                     # all steps, specific stack
./test-observability.sh --step <name>                    # single step, most recent deployment
./test-observability.sh <stack-name> --step <name>       # single step, specific stack
```

| Step | What it checks |
|---|---|
| `cloudwatch` | CloudWatch agent active on all nodes (via SSM) |
| `logs` | Application log group exists with the expected stream count |
| `flowlogs` | VPC flow log group exists and has ENI streams |
| `alarm` | Failed-auth alarm transitions to ALARM after 12 bad login attempts |
| `cloudtrail` | A multi-region CloudTrail trail exists and is logging |

The `alarm` step takes up to 7 minutes. All other steps complete in under a minute.

### 4. Tear Down

```bash
./teardown.sh                  # tears down the most recent deployment
./teardown.sh <stack-name>     # tears down a specific deployment
```

Deletes the CloudFormation stack, the SSM parameter created in local AMI mode, any cross-region AMI copy, and removes the deployment file from `.deploy/`. In `--marketplace` mode, only the stack and output file are deleted.

---

## Private — New VPC

Private subnets, internal NLB, and NAT Gateways — all created in a new VPC. The default topology.

### Build

Regenerate `templates/neo4j-private.template.yaml` from source partials after any edit to `templates/src/`:

```bash
cd templates && python build.py
```

### Deploy

```bash
./deploy.py                              # 3-node cluster, t3.medium, random region
./deploy.py --number-of-servers 1        # single instance
./deploy.py r8i                          # r8i.xlarge
./deploy.py --region eu-west-1           # specific region (AMI auto-copied if needed)
./deploy.py --marketplace                # use published Marketplace AMI
```

### Test

Run `preflight.sh` first to confirm the stack and bastion are ready:

```bash
cd validate-private
scripts/preflight.sh                     # 11 prerequisite checks: stack status, bastion SSM, VPC endpoints
```

Then validate the cluster:

```bash
uv run validate-private                  # 6 checks: Bolt, edition, listen address, memory, data dir, APOC
uv run run-cypher '<cypher>'             # execute a Cypher query, print JSON rows
scripts/smoke-write.sh                   # 20 CREATE...DELETE write operations through the cluster
uv run admin-shell                       # interactive cypher-shell session on the bastion
scripts/browser-tunnel.sh                # port-forward to NLB:7474 — open http://localhost:7474
```

All `validate-private/` commands default to the most recently modified file in `.deploy/`. Pass a stack name to target a specific deployment.

Run observability checks from the `neo4j-ee/` directory:

```bash
./test-observability.sh                  # CloudWatch, logs, flow logs, failed-auth alarm, CloudTrail
```

### Tear Down

```bash
./teardown.sh
```

> **Note:** Private mode provisions NAT Gateways (1 for single-instance, 3 for cluster), which incur hourly charges. Tear down promptly after testing.

---

## Public — New VPC

Public subnets, internet-facing NLB — all created in a new VPC. Intended for development and demos.

### Build

Regenerate `templates/neo4j-public.template.yaml` from source partials after any edit to `templates/src/`:

```bash
cd templates && python build.py
```

### Deploy

```bash
./deploy.py --mode Public                              # 3-node cluster, t3.medium, random region
./deploy.py --mode Public --number-of-servers 1        # single instance
./deploy.py --mode Public r8i                          # r8i.xlarge
./deploy.py --mode Public --region eu-west-1           # specific region
./deploy.py --mode Public --marketplace                # use published Marketplace AMI
```

`deploy.py` detects your public IP automatically and restricts the security group to `<your-ip>/32`. Pass `--allowed-cidr` to override.

### Test

The public template does not provision an operator bastion. Test with `test-observability.sh`:

```bash
./test-observability.sh                  # CloudWatch, logs, flow logs, failed-auth alarm, CloudTrail
```

Connection details (NLB DNS, Bolt URI) are in the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --region <region> \
  --query 'Stacks[0].Outputs' \
  --output table
```

### Tear Down

```bash
./teardown.sh
```

---

## Private — Existing VPC

Private subnets and internal NLB deployed into a VPC you supply. Use when you need the cluster inside an existing network (peered VPC, Transit Gateway, shared services account).

### Build

Regenerate `templates/neo4j-private-existing-vpc.template.yaml` from source partials after any edit to `templates/src/`:

```bash
cd templates && python build.py
```

### Deploy

Pass the VPC and subnet IDs at deploy time. One subnet is required for a single-instance deployment; all three are required for a three-node cluster:

```bash
# 1-node
./deploy.py --mode ExistingVpc \
  --number-of-servers 1 \
  --vpc-id vpc-xxxx \
  --subnet-1 subnet-xxxx

# 3-node
./deploy.py --mode ExistingVpc \
  --vpc-id vpc-xxxx \
  --subnet-1 subnet-a \
  --subnet-2 subnet-b \
  --subnet-3 subnet-c

# with Marketplace AMI
./deploy.py --marketplace --mode ExistingVpc \
  --vpc-id vpc-xxxx \
  --subnet-1 subnet-xxxx
```

`--allowed-cidr` defaults to `10.0.0.0/16`. Pass it explicitly if your VPC uses a different CIDR.

**`CreateVpcEndpoints` flag** — by default the template creates the four interface endpoints (`ssm`, `ssmmessages`, `logs`, `secretsmanager`). If your VPC already has these endpoints, set `--create-vpc-endpoints false` and pass `--existing-endpoint-sg-id <sg-id>` to avoid duplicate-endpoint deploy failures:

```bash
./deploy.py --mode ExistingVpc \
  --vpc-id vpc-xxxx --subnet-1 subnet-xxxx \
  --create-vpc-endpoints false \
  --existing-endpoint-sg-id sg-xxxx
```

### Test VPC Setup

For automated testing, `scripts/create-test-vpc.py` provisions a minimal private-networking VPC (`10.42.0.0/16`) and writes all resource IDs to `.deploy/vpc-<ts>.txt`. `deploy.py` reads that file automatically when `--mode ExistingVpc` and no `--vpc-id` is provided.

```bash
# Path A — template creates endpoints (default)
scripts/create-test-vpc.py --region us-east-1
./deploy.py --mode ExistingVpc --number-of-servers 3

# Path B — VPC already has endpoints (CreateVpcEndpoints=false)
scripts/create-test-vpc.py --region us-east-1 --with-endpoints
./deploy.py --mode ExistingVpc --number-of-servers 1 --create-vpc-endpoints false
```

Pass `--vpc-file <path>` to `deploy.py` to select a specific file when multiple vpc-*.txt files exist.

### Test

The existing-VPC template provisions an operator bastion. Use the same `validate-private/` tooling as the Private mode:

```bash
cd validate-private
scripts/preflight.sh                     # 11 prerequisite checks: stack status, bastion SSM, VPC endpoints
uv run validate-private                  # 7 cluster validation checks
uv run validate-private --suite failover   # failover suite (3-node only)
uv run validate-private --suite resilience # resilience suite (3-node only)
uv run run-cypher '<cypher>'             # execute a Cypher query
scripts/smoke-write.sh                   # write operations through the cluster
uv run admin-shell                       # interactive cypher-shell on the bastion
scripts/browser-tunnel.sh                # port-forward to NLB:7474
```

Run observability checks from the `neo4j-ee/` directory:

```bash
./test-observability.sh
```

### Tear Down

Tear down the EE stack first, then the test VPC if one was created:

```bash
./teardown.sh
scripts/teardown-test-vpc.py             # deletes VPC, NAT gateways, subnets, endpoints, removes vpc-*.txt
```

`teardown-test-vpc.py` defaults to the most recently modified `vpc-*.txt` in `.deploy/`. Pass a VPC deployment name (`vpc-<ts>`) to target a specific one.

> **Note:** The existing-VPC template does not create NAT Gateways — outbound routing is the responsibility of the VPC you supply. The test VPC created by `create-test-vpc.py` does provision NAT Gateways; tear it down promptly after testing.

---

## Where to Go Next

| Guide | What it covers |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Network topology, NLB routing, Bolt TLS, operator bastion design |
| [`PRIVATE_DEPLOY.md`](PRIVATE_DEPLOY.md) | Step-by-step private cluster deployment with Bolt TLS, SSM access, and app connectivity |
| [`OPERATOR_GUIDE.md`](OPERATOR_GUIDE.md) | Admin and testing with `validate-private/` — validation, admin shell, troubleshooting |
| [`APP_GUIDE.md`](APP_GUIDE.md) | Building applications that connect to a private cluster |

---

## Files

| File | Purpose |
|---|---|
| `templates/neo4j-private.template.yaml` | CloudFormation template — private, new VPC |
| `templates/neo4j-public.template.yaml` | CloudFormation template — public, new VPC |
| `templates/neo4j-private-existing-vpc.template.yaml` | CloudFormation template — private, existing VPC |
| `templates/build.py` | Assembles the three templates from `templates/src/` partials |
| `deploy.py` | Deploy helper — creates stack, waits, writes outputs to `.deploy/` |
| `teardown.sh` | Deletes the stack, SSM parameter, copied AMI, and deployment file |
| `test-observability.sh` | Automated observability checks (CloudWatch, logs, flow logs, alarm, CloudTrail) |
| `marketplace/` | AMI build and test scripts, Marketplace publishing instructions |
| `marketplace/create-ami.sh` | Automated AMI build — launches instance, runs hardening, creates AMI |
| `marketplace/test-ami.sh` | SSM-based AMI verification — no SSH key required |
| `marketplace/build.sh` | Hardening script run on the instance |
| `validate-private/` | Operator tooling for Private-mode and ExistingVpc-mode stacks |
| `sample-private-app/` | Sample Lambda app that connects to a private cluster |
| `scripts/create-test-vpc.py` | Create a minimal test VPC for ExistingVpc template testing; writes `.deploy/vpc-<ts>.txt` |
| `scripts/teardown-test-vpc.py` | Delete a test VPC created by `create-test-vpc.py`; reads `.deploy/vpc-<ts>.txt` |
| `.deploy/` | Deployment output files — one per stack (gitignored) |
