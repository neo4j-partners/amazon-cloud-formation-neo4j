# Neo4j Enterprise Edition: AWS CloudFormation

CloudFormation templates and tooling for the Neo4j Enterprise Edition AWS Marketplace listing. Supports single-instance and three-node cluster deployments fronted by a Network Load Balancer. Three topologies are available: public new VPC, private new VPC, and private existing VPC.

---

## Which template should I use?

| Your situation | Template | Guide |
|---|---|---|
| Proof of concept, demo, or evaluation | Public | [docs/PUBLIC.md](docs/PUBLIC.md) |
| Production or staging, new VPC | Private | [docs/PRIVATE.md](docs/PRIVATE.md) |
| Production or staging, existing VPC | Private, Existing VPC | [docs/PRIVATE-EXISTING-VPC.md](docs/PRIVATE-EXISTING-VPC.md) |

---

## Quick Start

All scripts read `AWS_PROFILE` from the environment and fall back to the `default` profile:

```bash
export AWS_PROFILE=<your-profile>   # omit to use your default profile
```

> **Marketplace publishing scripts only** (`marketplace/create-ami.sh`, `marketplace/test-ami.sh`): these must run against the `neo4j-marketplace` account (`385155106615`). Set `AWS_PROFILE=marketplace` before running them. All other scripts work with any account that has CloudFormation, SSM, EC2, and IAM permissions.

### Deploy

```bash
# Private (default): 3-node cluster, t3.medium
./deploy.py --region us-east-1

# Public
./deploy.py --mode Public --region us-east-1

# Existing VPC
./deploy.py --mode ExistingVpc --vpc-id vpc-xxxx --subnet-1 subnet-xxxx

# Common flags (apply to all modes)
./deploy.py --number-of-servers 1           # single instance instead of 3-node
./deploy.py r8i.xlarge                      # memory-optimized instance type
./deploy.py --marketplace                   # use the published Marketplace AMI
./deploy.py --alert-email you@example.com   # enable CloudWatch alarm emails
```

### Look Up Connection Details

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --region <region> \
  --query 'Stacks[0].Outputs' \
  --output table
```

### Tear Down

```bash
./teardown.sh                         # most recent deployment
./teardown.sh <stack-name>            # specific deployment
./teardown.sh --delete-volumes        # also permanently deletes EBS data volumes
```

EBS data volumes have `DeletionPolicy: Retain` and survive stack deletion by design. `teardown.sh` prints the retained volume IDs.

Multiple deployments can coexist; each gets its own file in `.deploy/`.

---

## Common Utilities

### Observability Checks

Verifies CloudWatch agent, application log streams, VPC flow logs, failed-auth alarm, and CloudTrail:

```bash
./test-observability.sh                   # most recent deployment
./test-observability.sh <stack-name>      # specific deployment
./test-observability.sh --step <name>     # single step (cloudwatch, logs, flowlogs, alarm, cloudtrail)
```

The `alarm` step takes up to 7 minutes. All others complete in under a minute.

### Private and Existing-VPC Validation

Full operator tooling for private-mode stacks lives in `validate-private/`:

```bash
cd validate-private
./scripts/preflight.sh              # 11 checks: stack, bastion, VPC endpoints
uv run validate-private             # cluster validation
uv run admin-shell                  # interactive cypher-shell via bastion
uv run run-cypher '<cypher>'        # one-off Cypher query
./scripts/smoke-write.sh            # write smoke test
./scripts/browser-tunnel.sh         # port-forward to Neo4j Browser
```

See [the Operator Guide in docs/PRIVATE.md](docs/PRIVATE.md#operator-guide) for the full workflow and troubleshooting reference.

---

## Modifying Templates

The three output templates are assembled from source partials in `templates/src/`. Edit the partials, then regenerate:

```bash
cd templates
python build.py
```

Commit both the edited partial(s) and the regenerated template file(s). The `--verify` flag checks whether the committed output is current, useful in CI:

```bash
python build.py --verify
```

---

## Template Guides

| Guide | What it covers |
|---|---|
| [docs/PUBLIC.md](docs/PUBLIC.md) | POC and demo deployments: public subnets, internet-facing NLB, direct access |
| [docs/PRIVATE.md](docs/PRIVATE.md) | Production deployments: private subnets, internal NLB, bastion access, Bolt TLS, full validation suite |
| [docs/PRIVATE-EXISTING-VPC.md](docs/PRIVATE-EXISTING-VPC.md) | Production deployments into an existing VPC: same cluster and bastion design, no VPC or NAT provisioning |

---

## For Application Developers

[APP_GUIDE.md](APP_GUIDE.md) covers building applications that connect to a private cluster: the SSM platform contract, VPC endpoint wiring, Lambda connection patterns, and CDK deployment examples.

---

## Marketplace Reference

[marketplace-reference.md](marketplace-reference.md) covers the AWS Marketplace listing, AMI build process, and publishing workflow.

---

## Files

| File | Purpose |
|---|---|
| `templates/neo4j-private.template.yaml` | CloudFormation template for private, new VPC deployments |
| `templates/neo4j-public.template.yaml` | CloudFormation template for public, new VPC deployments |
| `templates/neo4j-private-existing-vpc.template.yaml` | CloudFormation template for private, existing VPC deployments |
| `templates/src/` | Source partials assembled by `build.py` |
| `templates/build.py` | Assembles the three templates from `templates/src/` partials |
| `deploy.py` | Deploy helper: creates stack, waits, writes outputs to `.deploy/` |
| `teardown.sh` | Deletes the stack, SSM parameter, copied AMI, secrets, and deployment file |
| `test-observability.sh` | Observability checks: CloudWatch, logs, flow logs, alarm, CloudTrail |
| `validate-private/` | Operator tooling for Private and ExistingVpc stacks |
| `marketplace/` | AMI build and test scripts |
| `marketplace/create-ami.sh` | Builds AMI, writes ID to `marketplace/ami-id.txt` |
| `marketplace/test-ami.sh` | SSM-based AMI verification; no SSH key required |
| `scripts/create-test-vpc.py` | Creates a minimal test VPC for ExistingVpc template testing |
| `scripts/teardown-test-vpc.py` | Deletes a test VPC created by `create-test-vpc.py` |
| `sample-private-app/` | Sample Lambda app connecting to a private cluster |
| `.deploy/` | Deployment output files: one per stack (gitignored) |
