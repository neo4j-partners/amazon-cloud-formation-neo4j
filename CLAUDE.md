# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS CloudFormation templates for deploying Neo4j on AWS Marketplace. Two editions:

- **neo4j-ce/** — Community Edition. Single-instance with ASG-based resilience, persistent EBS volume, and Elastic IP.
- **neo4j-ee/** — Enterprise Edition. Supports 1 or 3 node clusters with Network Load Balancer.

All scripts expect `AWS_PROFILE=marketplace` (account 385155106615, neo4j-marketplace).

## Workflow Commands

All commands run from the edition directory (e.g., `neo4j-ce/`):

```bash
# Build base AMI (writes marketplace/ami-id.txt)
./marketplace/create-ami.sh

# Test AMI (SSM-based, no SSH)
./marketplace/test-ami.sh

# Deploy stack (reads marketplace/ami-id.txt, writes .deploy/<stack-name>.txt)
./deploy.sh                        # default: t3.medium, random region
./deploy.sh r8i                    # memory optimized: r8i.large
./deploy.sh --region eu-west-1     # specific region (AMI auto-copied)
./deploy.sh r8i --region us-east-2 # both

# Test stack (reads .deploy/<stack-name>.txt)
cd test_ce
uv run test-ce                           # full: latest deploy
uv run test-ce --stack <stack-name>      # specific deploy
uv run test-ce --simple                  # connectivity only
uv run test-ce --timeout 900             # custom ASG replacement timeout (default 600s)

# Tear down (deletes stack, SSM parameter, copied AMI, .deploy/<stack>.txt)
./teardown.sh                  # latest deploy
./teardown.sh <stack-name>     # specific deploy
```

## Architecture

### Deploy-time Install Strategy

The CE AMI is a base OS image (Amazon Linux 2023 with SSH hardening and OS patches). Neo4j Community Edition is installed from `yum.neo4j.com` at deploy time via the CloudFormation UserData script, which also handles runtime configuration (passwords, volumes, networking, APOC). This mirrors the EE pattern.

### CE Deployment Model

The CloudFormation template (`neo4j.template.yaml`) creates:
- VPC with single public subnet, Internet Gateway
- Auto Scaling Group (fixed size 1) for self-healing
- Separate GP3 EBS data volume (`DeletionPolicy: Retain`) attached at boot
- Elastic IP re-associated on each instance launch
- IAM role with policies for CFN signaling, EBS attachment, EIP association

**UserData boot sequence**: install Neo4j from yum → attach/mount EBS (format on first boot only) → associate EIP → install APOC (if enabled) → configure Neo4j → set password (first boot only) → start Neo4j → signal CloudFormation.

### NVMe Device Resolution

Nitro instances expose EBS as NVMe devices with non-deterministic names. The UserData script resolves the correct device by matching the EBS volume serial number (with dashes stripped) against `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*`.

### Key File Flow

`create-ami.sh` → writes `marketplace/ami-id.txt` → `deploy.sh` reads it, deploys stack (random region, copies AMI if needed), writes `.deploy/<stack-name>.txt` → `test_ce/` and `test-stack.sh` read from `.deploy/` (newest by default, or `--stack <name>`) → `teardown.sh` cleans up (stack, SSM param, copied AMI, output file).

## Test Suite (test_ce/)

Python project using `uv` for dependency management. Requires Python 3.11+.

- **Simple mode** (`--simple`): HTTP API, authentication, Bolt connectivity, APOC check
- **Full mode** (default): Simple mode + write sentinel data, terminate instance, wait for ASG replacement, verify data persisted on new instance

Key modules: `neo4j_checks.py` (connectivity), `resilience.py` (EBS persistence), `aws_helpers.py` (boto3 operations).

## Template Editing Notes

- UserData is embedded in the LaunchTemplate within `neo4j.template.yaml` (CE: lines ~314-593). Use `Fn::Sub` for CloudFormation variable interpolation.
- The `set_neo4j_conf()` bash function in UserData is idempotent — it updates existing keys or appends new ones.
- Security group opens ports 7474 (HTTP/Browser) and 7687 (Bolt) to `AllowedCIDR`.
- IMDSv2 is enforced (`HttpTokens: required` in LaunchTemplate metadata options).

## Debugging Deployed Stacks

Check logs on the EC2 instance:
1. `/var/log/cloud-init-output.log` — UserData execution
2. `/var/log/neo4j/debug.log` — Neo4j application logs
