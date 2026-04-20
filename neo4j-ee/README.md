# Neo4j Enterprise Edition — AWS Marketplace

CloudFormation template and tooling for the Neo4j Enterprise Edition AWS Marketplace listing. Supports single-instance and three-node cluster deployments fronted by a Network Load Balancer.

## Quick Start — CLI Deployment

All scripts read `AWS_PROFILE` from the environment and fall back to the `default` profile if it is not set:

```bash
export AWS_PROFILE=<your-profile>   # omit to use your default AWS profile
```

> **Marketplace publishing scripts only** (`marketplace/create-ami.sh`, `marketplace/test-ami.sh`): these must run against the `neo4j-marketplace` AWS account (account `385155106615`). Set `AWS_PROFILE=marketplace` before running them. All other scripts (`deploy.sh`, `teardown.sh`, `test-observability.sh`) work with any account that has CloudFormation, SSM, EC2, and IAM permissions.

### 1. Deploy the Stack

Two AMI modes depending on what you are testing.

**Marketplace mode** — uses the published Marketplace AMI directly. No local AMI file needed:

```bash
./deploy.sh --marketplace                                  # t3.medium, 3 nodes, random region, Private mode
./deploy.sh --marketplace r8i                              # memory optimized (r8i.xlarge)
./deploy.sh --marketplace --number-of-servers 1            # single instance
./deploy.sh --marketplace --region eu-west-1               # specific region
./deploy.sh --marketplace --mode Public                    # internet-facing NLB (opt-in)
./deploy.sh --marketplace --alert-email you@example.com    # enable CloudWatch alarm emails
```

**Local AMI mode** — tests a newly built AMI before it is published. Build and verify the AMI first (requires the `neo4j-marketplace` account):

```bash
AWS_PROFILE=marketplace ./marketplace/create-ami.sh   # builds AMI, writes ID to marketplace/ami-id.txt
AWS_PROFILE=marketplace ./marketplace/test-ami.sh     # verifies SSH hardening and OS
```

Then deploy using that AMI:

```bash
./deploy.sh                                    # t3.medium, 3 nodes, random region, Private mode
./deploy.sh r8i                                # memory optimized (r8i.xlarge)
./deploy.sh --number-of-servers 1              # single instance
./deploy.sh --region eu-west-1                 # specific region (AMI auto-copied)
./deploy.sh --mode Public                      # internet-facing NLB (opt-in)
./deploy.sh --alert-email you@example.com      # enable CloudWatch alarm emails
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

`test-observability.sh` verifies the Phase 1 observability components the CloudFormation template provisions: CloudWatch agent, application log streams, VPC flow logs, failed-auth alarm, and CloudTrail.

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

> **Note:** Private mode provisions NAT Gateways (1 for single-instance, 3 for cluster), which incur hourly charges. Tear down promptly after testing.

Deletes the CloudFormation stack, the SSM parameter created in local AMI mode, any cross-region AMI copy, and removes the deployment file from `.deploy/`. In `--marketplace` mode, only the stack and output file are deleted.

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
| `neo4j.template.yaml` | CloudFormation template |
| `deploy.sh` | Deploy helper — creates stack, waits, writes outputs to `.deploy/` |
| `teardown.sh` | Deletes the stack, SSM parameter, copied AMI, and deployment file |
| `test-observability.sh` | Automated observability checks (CloudWatch, logs, flow logs, alarm, CloudTrail) |
| `marketplace/` | AMI build and test scripts, Marketplace publishing instructions |
| `marketplace/create-ami.sh` | Automated AMI build — launches instance, runs hardening, creates AMI |
| `marketplace/test-ami.sh` | SSM-based AMI verification — no SSH key required |
| `marketplace/build.sh` | Hardening script run on the instance |
| `validate-private/` | Operator tooling for Private-mode stacks |
| `sample-private-app/` | Sample Lambda app that connects to a private cluster |
| `.deploy/` | Deployment output files — one per stack (gitignored) |
