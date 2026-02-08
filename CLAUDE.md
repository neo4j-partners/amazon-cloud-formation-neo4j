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
# Build AMI (writes marketplace/ami-id.txt)
./marketplace/create-ami.sh <neo4j-version>    # e.g., 2026.01.3

# Test AMI (SSM-based, no SSH)
./marketplace/test-ami.sh

# Deploy stack (reads marketplace/ami-id.txt, writes stack-outputs.txt)
./deploy.sh              # default: t3.medium
./deploy.sh r8i          # memory optimized: r8i.large

# Test stack (reads stack-outputs.txt)
cd test_ce
uv run test-ce                # full: connectivity + EBS resilience
uv run test-ce --simple       # connectivity only
uv run test-ce --timeout 900  # custom ASG replacement timeout (default 600s)

# Tear down (deletes stack, SSM parameter, stack-outputs.txt)
./teardown.sh
```

## Architecture

### Hybrid AMI Strategy

AMIs are pre-baked with Java 21 (Corretto) and Neo4j binaries via `marketplace/build.sh`. Runtime configuration (passwords, volumes, networking, APOC) happens in the CloudFormation UserData script at boot.

### CE Deployment Model

The CloudFormation template (`neo4j.template.yaml`) creates:
- VPC with single public subnet, Internet Gateway
- Auto Scaling Group (fixed size 1) for self-healing
- Separate GP3 EBS data volume (`DeletionPolicy: Retain`) attached at boot
- Elastic IP re-associated on each instance launch
- IAM role with policies for CFN signaling, EBS attachment, EIP association

**UserData boot sequence**: stop Neo4j → attach/mount EBS (format on first boot only) → associate EIP → install APOC (if enabled) → configure Neo4j → set password (first boot only) → start Neo4j → signal CloudFormation.

### NVMe Device Resolution

Nitro instances expose EBS as NVMe devices with non-deterministic names. The UserData script resolves the correct device by matching the EBS volume serial number (with dashes stripped) against `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*`.

### Key File Flow

`create-ami.sh` → writes `marketplace/ami-id.txt` → `deploy.sh` reads it, deploys stack, writes `stack-outputs.txt` → `test_ce/` reads `stack-outputs.txt` → `teardown.sh` cleans up.

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
