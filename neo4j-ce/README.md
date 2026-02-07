# Neo4j Community Edition — AWS Marketplace

CloudFormation template and tooling for the Neo4j Community Edition AWS Marketplace listing.

## Quick Start

All scripts use the `marketplace` AWS CLI profile. Export it once so every command picks it up:

```bash
export AWS_PROFILE=marketplace
```

### 1. Build the AMI

```bash
./marketplace/create-ami.sh 2025.12.0
```

This builds the AMI and writes the ID to `marketplace/ami-id.txt`. See [marketplace/README.md](marketplace/README.md) for details.

### 2. Test the AMI

```bash
# Test (reads ami-id.txt automatically)
./test-ami.sh
```

### 3. Deploy the Stack

```bash
./deploy.sh <stack-name>
```

The script reads the AMI ID from `marketplace/ami-id.txt` automatically. You can also pass it explicitly:

```bash
./deploy.sh <stack-name> ami-089ef8c9f4da68869
```

The script waits for the stack to complete, then writes connection details and deploy context to `stack-outputs.txt`.

### 4. Test the Stack

```bash
cd test_ce
uv run test-ce
```

The Python test suite in `test_ce/` reads `stack-outputs.txt` (written by `deploy.sh`) and runs two levels of testing:

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
uv run test-ce                # full mode (connectivity + EBS resilience)
uv run test-ce --simple       # connectivity only
uv run test-ce --password pw  # override password from stack-outputs.txt
uv run test-ce --timeout 900  # ASG replacement timeout in seconds (default: 600)
```

> The legacy `test-stack.sh` script is equivalent to `uv run test-ce --simple`.

### 5. Tear Down

```bash
./teardown.sh
```

Deletes the CloudFormation stack, the SSM parameter created by `deploy.sh`, and removes `stack-outputs.txt`.

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
| `deploy.sh` | Local deploy helper — creates stack, waits, writes outputs |
| `test-stack.sh` | Legacy connectivity tests (HTTP, Bolt, auth, APOC) |
| `test_ce/` | Python test suite — connectivity + EBS resilience testing |
| `teardown.sh` | Deletes the stack, SSM parameter, and local outputs |
| `marketplace/` | AMI build scripts and Marketplace publishing instructions |
| `marketplace/ami-id.txt` | AMI ID from last build (gitignored) |
| `stack-outputs.txt` | Connection details and deploy context from last deploy (gitignored) |
