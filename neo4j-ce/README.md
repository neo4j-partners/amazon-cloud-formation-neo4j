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
./test-stack.sh
```

Requires `cypher-shell` installed locally. The script reads `stack-outputs.txt` (written by `deploy.sh`), waits for the NLB endpoint to become reachable, then runs HTTP, authentication, Bolt, and APOC tests.

To override the password: `./test-stack.sh --password <password>`

### 5. Tear Down

```bash
./teardown.sh
```

Deletes the CloudFormation stack, the SSM parameter created by `deploy.sh`, and removes `stack-outputs.txt`.

## What Gets Deployed

- VPC with a single public subnet
- Internet-facing Network Load Balancer (ports 7474, 7687)
- Auto Scaling Group (fixed at 1 instance) with ELB health checks
- GP3 EBS volume (encrypted)
- Security group allowing inbound on 7474 and 7687

## Files

| File | Purpose |
|---|---|
| `neo4j.template.yaml` | CloudFormation template |
| `deploy.sh` | Local deploy helper — creates stack, waits, writes outputs |
| `test-stack.sh` | Validates a deployed stack (HTTP, Bolt, auth, APOC) |
| `teardown.sh` | Deletes the stack, SSM parameter, and local outputs |
| `marketplace/` | AMI build scripts and Marketplace publishing instructions |
| `marketplace/ami-id.txt` | AMI ID from last build (gitignored) |
| `stack-outputs.txt` | Connection details and deploy context from last deploy (gitignored) |
