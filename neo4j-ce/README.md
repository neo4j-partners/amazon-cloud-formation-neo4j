# Neo4j Community Edition — AWS Marketplace

CloudFormation template and tooling for the Neo4j Community Edition AWS Marketplace listing.

## Quick Start

All scripts use the `marketplace` AWS CLI profile. Export it once so every command picks it up:

```bash
export AWS_PROFILE=marketplace
```

### 1. Build the Base AMI

```bash
./marketplace/create-ami.sh
```

This builds the base OS AMI (Neo4j is installed at deploy time from yum) and writes the ID to `marketplace/ami-id.txt`. See [marketplace/README.md](marketplace/README.md) for details.

### 2. Test the AMI

```bash
# Test (reads ami-id.txt automatically)
./test-ami.sh
```

### 3. Deploy the Stack

```bash
./deploy.sh                        # default: t3.medium, random region
./deploy.sh r8i                    # memory optimized (r8i.large)
./deploy.sh --region eu-west-1     # specific region (AMI auto-copied)
./deploy.sh r8i --region us-east-2 # both
```

The script reads the AMI ID from `marketplace/ami-id.txt` (written by `create-ami.sh`), picks a random region (or uses `--region`), copies the AMI cross-region if needed, deploys the stack, waits for completion, then writes connection details and deploy context to `.deploy/<stack-name>.txt`.

Multiple deployments can coexist — each gets its own output file in `.deploy/`.

### 4. Test the Stack

```bash
cd test_ce
uv run test-ce
```

The Python test suite in `test_ce/` reads from `.deploy/` (most recently modified file by default) and runs two levels of testing:

**Simple mode** (`--simple`) — connectivity only:
1. **HTTP API** — GET the discovery endpoint, verify `neo4j_version` is present
2. **Authentication** — POST a Cypher statement with Basic Auth, expect HTTP 200
3. **Bolt connectivity** — connect via the Neo4j driver and execute `RETURN 1`
4. **APOC plugin** — call `apoc.version()` (skipped if APOC not installed)

**Full mode** (default) — connectivity + EBS persistence:
5. **Write sentinel data** — create a `Sentinel` node with a unique test ID
6. **Terminate EC2 instance** — kill the running instance via the ASG
7. **Wait for ASG replacement** — poll the ASG until a new instance is InService
8. **Re-run connectivity tests** — verify HTTP, Auth, Bolt, and APOC on the replacement
9. **Verify sentinel data persisted** — confirm the sentinel node survived instance replacement (proves the EBS volume was reattached)

```bash
uv run test-ce                              # full mode (connectivity + EBS resilience)
uv run test-ce --simple                     # connectivity only
uv run test-ce --stack <stack-name>         # test a specific deployment
uv run test-ce --password pw                # override password from outputs file
uv run test-ce --timeout 900                # ASG replacement timeout in seconds (default: 600)
```

> The legacy `test-stack.sh` script is equivalent to `uv run test-ce --simple`. It also accepts `--stack <stack-name>`.

### 5. Tear Down

```bash
./teardown.sh                  # tears down the most recent deployment
./teardown.sh <stack-name>     # tears down a specific deployment
```

Deletes the CloudFormation stack, the SSM parameter created by `deploy.sh`, any cross-region AMI copy, and removes the deployment file from `.deploy/`.

## What Gets Deployed

- VPC with a single public subnet
- Elastic IP (stable public address, re-associated on instance replacement)
- Auto Scaling Group (fixed at 1 instance) with EC2 health checks
- GP3 EBS data volume (encrypted, persists across instance replacement)
- Security group allowing inbound on 7474 and 7687

## Files

| File | Purpose |
|---|---|
| `neo4j.template.yaml` | CloudFormation template |
| `deploy.sh` | Local deploy helper — creates stack, waits, writes outputs to `.deploy/` |
| `test-stack.sh` | Legacy connectivity tests (HTTP, Bolt, auth, APOC) |
| `test_ce/` | Python test suite — connectivity + EBS resilience testing |
| `teardown.sh` | Deletes the stack, SSM parameter, copied AMI, and deployment file |
| `marketplace/` | AMI build scripts and Marketplace publishing instructions |
| `marketplace/ami-id.txt` | AMI ID from last build (gitignored) |
| `.deploy/` | Deployment output files — one per stack (gitignored) |
