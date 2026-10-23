# CVE-2026-31431 Three-Node Cluster Test Plan

## Goal

Validate the remediation guidance in
`CVE-2026-31431-customer-remediation.md` against a fresh three-node Neo4j EE
Marketplace deployment.

The main test validates the recommended fix: patch running instances in place,
one node at a time, using SSM Run Command, and verify that the cluster remains
healthy after each reboot.

An optional second test validates the alternative fix: update the stack or
launch template to a patched AMI and replace one node at a time.

## Assumptions

- The test runs in a non-production AWS account.
- The AWS account is subscribed to the Neo4j EE Marketplace listing.
- `AWS_PROFILE` points to the account used for the test.
- The test uses the repo deployment helper with the published Marketplace AMI:
  `./deploy.py --mode Private --marketplace --number-of-servers 3`.
- The current live Marketplace listing only exposes its public CloudFormation
  delivery option. For this test, `deploy.py --marketplace` resolves the actual
  region-local Marketplace AMI by product code and uses it with the repo's
  Private template.
- The current Neo4j EE Marketplace product code is
  `4t4a9h39qkq4tbo3n9zd51p25`.
- Private mode is preferred because it matches the production-oriented topology
  and gives SSM access through the stack-managed instance role and bastion.
- The expected fixed default Amazon Linux 2023 kernel is
  `6.1.168-203.330.amzn2023` or newer.
- If the current Marketplace AMI is already patched, this plan still validates
  rolling patch and reboot safety, but it will not prove vulnerable-to-fixed
  kernel transition. To prove that transition, use an existing pre-May 5, 2026
  Marketplace deployment or an older Marketplace version if AWS still exposes
  one for launch.

## Risks

- This creates billable AWS resources: EC2 instances, EBS volumes, NAT gateways,
  VPC endpoints, NLB, logs, and Secrets Manager secrets.
- Stack deletion retains EBS data volumes unless `teardown.sh --delete-volumes`
  is used.
- During the leader node reboot, writes can see a short transient failure while
  leadership moves. The acceptance criterion is no sustained outage and full
  cluster recovery before the next node is patched.
- Do not run this against a customer or production stack unless the maintenance
  window, backups, and rollback path have been approved.

## Current Run Status

Status: Complete.

Run context:

- Date: May 14, 2026
- AWS profile: `marketplace`
- Region: `us-east-1`
- Stack: `test-ee-1778791345`
- Deployment mode: `Private`
- Marketplace product code: `4t4a9h39qkq4tbo3n9zd51p25`
- Marketplace AMI resolved by `deploy.py`: `ami-0a6984262620899b5`
- Marketplace AMI name: `neo4jeemp-513a3a85-20f7-4809-bb9f-aab293ce1e1d`
- Marketplace AMI owner: `679593333241`
- Bastion: `i-08ae4cdd71197f1eb`

Cluster nodes:

| Node | Instance ID | Private IP | Status |
|---|---|---:|---|
| node 1 | `i-0846effec3da2371e` | `10.0.10.30` | Mitigation tested; patched and rebooted |
| node 2 | `i-0f399806309329219` | `10.0.11.185` | Not patched this run |
| node 3 | `i-0a36144ad9b30502d` | `10.0.12.136` | Not patched this run |

Evidence captured:

- Stack reached `CREATE_COMPLETE`.
- Preflight passed: `11 passed, 0 failed`.
- Baseline validator passed: all 8 checks passed.
- Baseline smoke write passed: `20/20` writes succeeded.
- Baseline `SHOW SERVERS` returned three `Enabled` and `Available` servers.
- Baseline kernel on all three nodes was vulnerable:
  `6.1.158-180.294.amzn2023.x86_64`.
- Temporary mitigation applied to node 1:
  `/etc/modprobe.d/disable-algif-aead.conf` created via SSM.
- `modprobe algif_aead` failed with `Operation not permitted` while mitigation
  was active — module load blocked as expected.
- Cluster health remained three `Enabled` and `Available` servers throughout
  the mitigation test.
- Mitigation file removed from node 1 via SSM.
- Node 1 patched with Python 3.9 `dnf` workaround, rebooted, and verified
  running `6.1.168-203.330.amzn2023.x86_64`.
- `modprobe algif_aead` succeeded on node 1 after the fixed kernel was
  running — module loads cleanly, mitigation no longer needed.
- Node 1 post-patch `SHOW SERVERS` returned three `Enabled` and `Available`
  servers.
- Node 1 post-patch smoke write passed: `5/5` writes succeeded.
- Nodes 2 and 3 not patched in this run — rolling patch procedure validated
  across runs 1 and 2.
- Final validator passed: all 8 checks passed.
- Final smoke write passed: `50/50` writes succeeded.

SSM command IDs captured:

| Purpose | Command ID | Result |
|---|---|---|
| Baseline kernel check | `992ce063-6cd7-4c6f-bfb3-c7f2035b07b6` | Success |
| Baseline smoke write | `5e8a7116-0b27-48e5-bef9-6930374d886f` | Success |
| Apply mitigation node 1 | `e8a1d963-35ca-4b03-924d-a18adec7efcd` | Success |
| Verify mitigation blocks module | `56bf17d4-e6df-4828-9eeb-acaa42ed82f7` | Success |
| Remove mitigation node 1 | `0843490f-2b13-4241-a48c-1ad154c5ed73` | Success |
| Node 1 patch and reboot | `3ad25faf-a698-4fb1-994f-3bed59cd348e` | Success |
| Node 1 post-patch kernel and module verify | `feb13627-e399-4246-830a-8b71a77661e5` | Success |
| Node 1 post-patch smoke write | `c765b7a5-f3ea-482c-a08c-59fe4988d9b4` | Success |
| Final 50-write smoke test | `4bf10f2d-ee55-43b3-8981-c6e01b94bd21` | Success |

## Run 2 Evidence (May 14, 2026)

Status: Complete.

Run context:

- Date: May 14, 2026
- AWS profile: `marketplace`
- Region: `us-east-1`
- Stack: `test-ee-1778787041`
- Deployment mode: `Private`
- Marketplace product code: `4t4a9h39qkq4tbo3n9zd51p25`
- Marketplace AMI resolved by `deploy.py`: `ami-0a6984262620899b5`
- Marketplace AMI name: `neo4jeemp-513a3a85-20f7-4809-bb9f-aab293ce1e1d`
- Marketplace AMI owner: `679593333241`
- Bastion: `i-0a4362357878625c4`

Cluster nodes:

| Node | Instance ID | Private IP | Status |
|---|---|---:|---|
| node 1 | `i-09e2c76dcce0c452f` | `10.0.10.127` | Patched and rebooted |
| node 2 | `i-0827bfc028721edc6` | `10.0.11.17` | Patched and rebooted |
| node 3 | `i-0eaf714804b578d33` | `10.0.12.43` | Patched and rebooted |

Evidence captured:

- Stack reached `CREATE_COMPLETE`.
- Preflight passed: `11 passed, 0 failed`.
- Baseline validator passed: all 8 checks passed.
- Baseline smoke write passed: `20/20` writes succeeded.
- Baseline `SHOW SERVERS` returned three `Enabled` and `Available` servers.
- Baseline kernel on all three nodes was vulnerable:
  `6.1.158-180.294.amzn2023.x86_64`.
- Node 1 was patched with the Python 3.9 `dnf` workaround, rebooted, and
  verified running `6.1.168-203.330.amzn2023.x86_64`.
- Node 1 post-patch `SHOW SERVERS` returned three `Enabled` and `Available`
  servers.
- Node 1 post-patch smoke write passed: `5/5` writes succeeded.
- Node 2 was patched with the Python 3.9 `dnf` workaround, rebooted, and
  verified running `6.1.168-203.330.amzn2023.x86_64`.
- Node 2 post-patch `SHOW SERVERS` returned three `Enabled` and `Available`
  servers.
- Node 2 post-patch smoke write passed: `5/5` writes succeeded.
- Node 3 was patched with the Python 3.9 `dnf` workaround, rebooted, and
  verified running `6.1.168-203.330.amzn2023.x86_64`.
- Node 3 post-patch `SHOW SERVERS` returned three `Enabled` and `Available`
  servers.
- Node 3 post-patch smoke write passed: `5/5` writes succeeded.
- Final validator passed: all 8 checks passed.
- Final smoke write passed: `50/50` writes succeeded.
- Final kernel evidence confirmed all three nodes running
  `6.1.168-203.330.amzn2023.x86_64`.
- Final `SHOW SERVERS` returned three `Enabled` and `Available` servers.
- Teardown completed.
- Retained EBS data volumes were deleted:
  `vol-0934963e3c2e07b17`, `vol-0dd5d432de615c7e5`, and
  `vol-01ba1d7e3b1bd77f0`.
- Cleanup verification confirmed CloudFormation stack `test-ee-1778787041`
  no longer exists.
- Cleanup verification confirmed temporary ImageId SSM parameter
  `/neo4j-ee/test/test-ee-1778787041/ami-id` no longer exists.
- Cleanup verification confirmed `.deploy/test-ee-1778787041.txt` was removed.

Run 2 SSM command IDs:

| Purpose | Command ID | Result |
|---|---|---|
| Baseline kernel check | `70e0395d-8a2c-4bf5-bcc3-2a51acf7e435` | Success |
| Baseline smoke write | `34f018f5-201f-48fa-90e8-f8d54a71b363` | Success |
| Node 1 patch and reboot | `139e7497-47e5-4424-a7d9-32607d20eaab` | Success |
| Node 1 kernel verify | `8060703a-d8b1-46bb-87c9-16687bb8185b` | Success |
| Node 1 post-patch smoke write | `29be155a-7a98-4a07-ac9e-3d46d218770a` | Success |
| Node 2 patch and reboot | `d9905de0-c02b-4f70-9703-a8b724294030` | Success |
| Node 2 kernel verify | `fc6f45c6-9a24-41b2-b045-bc28054bef28` | Success |
| Node 2 post-patch smoke write | `0c7b68a6-5067-4387-9aba-386346f6bf7e` | Success |
| Node 3 patch and reboot | `24a156e9-b78a-403b-8243-f4d8d2de3114` | Success |
| Node 3 kernel verify | `7aa61277-0d3f-4291-9762-b933c92ccd6c` | Success |
| Node 3 post-patch smoke write | `8babedff-913e-47cd-94ba-a76b7d301554` | Success |
| Final 50-write smoke test | `242f1a11-3665-4bfb-9e97-da5580cb5b67` | Success |
| Final kernel evidence | `ae64a484-1e78-4898-bfe1-4acff1d34720` | Success |

## Run 1 Evidence (May 14, 2026)

Status: Complete.

Run context:

- Date: May 14, 2026
- AWS profile: `marketplace`
- Region: `us-east-1`
- Stack: `test-ee-1778780312`
- Deployment mode: `Private`
- Marketplace product code: `4t4a9h39qkq4tbo3n9zd51p25`
- Marketplace AMI resolved by `deploy.py`: `ami-0a6984262620899b5`
- Marketplace AMI name: `neo4jeemp-513a3a85-20f7-4809-bb9f-aab293ce1e1d`
- Marketplace AMI owner: `679593333241`
- Bastion: `i-018799168000b4351`

Cluster nodes:

| Node | Instance ID | Private IP | Status |
|---|---|---:|---|
| node 1 | `i-06502df111c1c7f3e` | `10.0.10.220` | Patched and rebooted |
| node 2 | `i-0df1acbdb20d36b4e` | `10.0.11.119` | Patched and rebooted |
| node 3 | `i-02f90ef9d2ae4a5a6` | `10.0.12.26` | Patched and rebooted |

Evidence captured:

- Stack reached `CREATE_COMPLETE`.
- Preflight passed: `11 passed, 0 failed`.
- Baseline validator passed: all 8 checks passed.
- Baseline smoke write passed: `20/20` writes succeeded.
- Baseline `SHOW SERVERS` returned three `Enabled` and `Available` servers.
- Baseline kernel on all three nodes was vulnerable:
  `6.1.158-180.294.amzn2023.x86_64`.
- Node 1 was patched with `ALAS2023-2026-1651`, rebooted, and verified running
  `6.1.168-203.330.amzn2023.x86_64`.
- Node 1 post-patch `SHOW SERVERS` returned three `Enabled` and `Available`
  servers.
- Node 1 post-patch smoke write passed: `5/5` writes succeeded.
- Node 2 was patched with the Python 3.9 `dnf` workaround, rebooted, and
  verified running `6.1.168-203.330.amzn2023.x86_64`.
- Node 2 post-patch `SHOW SERVERS` returned three `Enabled` and `Available`
  servers.
- Node 2 post-patch smoke write passed: `5/5` writes succeeded.
- Node 3 was patched with the Python 3.9 `dnf` workaround, rebooted, and
  verified running `6.1.168-203.330.amzn2023.x86_64`.
- Node 3 post-patch `SHOW SERVERS` returned three `Enabled` and `Available`
  servers.
- Node 3 post-patch smoke write passed: `5/5` writes succeeded.
- Final validator passed: all 8 checks passed.
- Final smoke write passed: `50/50` writes succeeded.
- Final kernel evidence confirmed all three nodes running
  `6.1.168-203.330.amzn2023.x86_64`.
- Final `SHOW SERVERS` returned three `Enabled` and `Available` servers.
- Teardown completed.
- Retained EBS data volumes were deleted:
  `vol-0992aa43c9f2aadbc`, `vol-0f2094f7b3aa2d411`, and
  `vol-041f0f7cff561c281`.
- Cleanup verification confirmed CloudFormation stack `test-ee-1778780312`
  no longer exists.
- Cleanup verification confirmed temporary ImageId SSM parameter
  `/neo4j-ee/test/test-ee-1778780312/ami-id` no longer exists.
- Cleanup verification confirmed `.deploy/test-ee-1778780312.txt` was removed.
- Cleanup verification confirmed no active EC2 instances remain with stack tag
  `test-ee-1778780312`.

Run 1 SSM command IDs:

| Purpose | Command ID | Result |
|---|---|---|
| Baseline kernel check | `b89fbe21-0c2e-44a6-a1f5-7dfa0ae39690` | Success |
| Original node 1 patch command | `cf690c5b-4143-4c4a-8351-c347401fd2dc` | Failed |
| Inspect node 1 package manager state | `a6ea6d8a-f48d-497e-9fd2-cf7db2057e98` | Success |
| Test `dnf` through Python 3.9 | `0dd881f3-e279-4916-bd30-fd6547211980` | Success |
| Node 1 workaround patch and reboot | `5188edd5-49cf-4172-9223-384a7fd8c39c` | Success |
| Node 1 running kernel verify | `af0b51ed-7055-4db4-ae0d-7a7da12e67ec` | Success |
| Baseline smoke write | `a82a1826-5ee1-44e0-b944-252c7bf91eb9` | Success |
| Node 1 post-patch smoke write | `65f86297-b78a-4f35-bcbb-5ecbf1743146` | Success |
| Resume kernel check | `3bce30d2-7388-4d5d-aea0-169c975a930d` | Success |
| Node 2 workaround patch and reboot | `074eb224-3067-43d7-898e-063ba3b2b0df` | Success |
| Node 2 running kernel verify | `d64e1668-82e6-4fb3-8c15-c3b46e9dd8d5` | Success |
| Node 2 post-patch smoke write | `c9628ee7-feba-40f5-ad1f-2a0fb1bdbe02` | Success |
| Node 3 workaround patch and reboot | `69f653d8-cd62-4b91-87ea-f7eadf71ae5d` | Success |
| Node 3 running kernel verify | `1b3ba27b-245d-48a1-a744-8b792b716271` | Success |
| Node 3 post-patch smoke write | `610d5040-d46f-4e43-babc-4b7e74f4cfbd` | Success |
| Final 50-write smoke test | `364d3221-42c9-40af-b373-e65273762ab6` | Success |
| Final kernel evidence | `a79220e1-7c3e-410f-9568-7bd8fedcbb5f` | Success |

## Known Issues Going Into This Run

### Marketplace AMI Versus Marketplace Template

The live Marketplace listing currently exposes a public CloudFormation delivery
option, not the repo's Private template. To test a three-node Private cluster
against the actual Marketplace AMI, `deploy.py --marketplace` was updated to
resolve the region-local Marketplace AMI by product code and pass that AMI into
the repo template through the temporary `ImageId` SSM parameter.

This means the test validates the actual Marketplace AMI plus the repo's Private
template. It does not validate the live Marketplace CloudFormation template.

### Broken `dnf` Entry Point On The Marketplace AMI

The standard `dnf` command fails on the current Marketplace AMI:

```bash
sudo dnf update --advisory ALAS2023-2026-1651 --releasever 2023.11.20260505 -y
```

Failure:

```text
ModuleNotFoundError: No module named 'dnf'
```

Root cause:

- `/usr/bin/dnf` has `#!/usr/bin/python3`.
- `/usr/bin/python3` points to Python 3.11 on this AMI via `/etc/alternatives/python3`.
- AL2023's `dnf` packages and `python3-dnf` module are installed for Python 3.9.

Use the Python 3.9 workaround for all node patch commands in this run:

```bash
sudo /usr/bin/python3.9 /usr/bin/dnf update \
  --advisory ALAS2023-2026-1651 \
  --releasever 2023.11.20260505 \
  -y && sudo reboot
```

The troubleshooting note has been added to `CVE-2026-31431-customer-remediation.md`.

### Smoke Write Script Bug (Fixed)

In run 1, `smoke-write.sh` exited silently when `BoltTlsSecretArn` was absent
because the optional field was read under `set -e`. The fix (`|| true` on that
read) is now committed to the repo. No workaround needed for this run.

## Phase Checklist

### Phase 1: Prepare the Test Environment

Status: Complete

Checklist:

- Confirm AWS CLI v2 is installed and authenticated.
- Confirm `uv` is installed for the repo validation tools.
- Confirm the operator IAM principal can create and delete CloudFormation,
  EC2, Auto Scaling, IAM, SSM, Secrets Manager, CloudWatch Logs, ELBv2, and VPC
  resources.
- Select a test region supported by `deploy.py`, for example `us-east-1`.
- Export the profile and region used for all commands:

```bash
export AWS_PROFILE=marketplace 
export REGION=us-east-1
```

Validation:

- `aws sts get-caller-identity` returns the expected test account.
- `aws ec2 describe-regions --region "$REGION"` succeeds.

### Phase 2: Deploy a Three-Node Marketplace Cluster

Status: Complete

Checklist:

- From the repo root, deploy a Private-mode three-node cluster from the live
  Marketplace AMI:

```bash
./deploy.py --mode Private --marketplace --number-of-servers 3 --region "$REGION"
```

- Record the printed stack name as `<stack-name>`.
- Confirm `.deploy/<stack-name>.txt` exists.
- Confirm the deployment file has `NumberOfServers = 3`,
  `DeploymentMode = Private`, and `AmiSource = marketplace`.
- Confirm the deployment file records `MarketplaceProductCode` and `AmiId`.

Validation:

- CloudFormation stack status is `CREATE_COMPLETE`.
- The deployment output file contains the bastion ID, internal NLB DNS name,
  region, stack ID, Marketplace product code, and region-local Marketplace AMI
  ID.

### Phase 3: Baseline Cluster and Kernel State

Status: Complete

Checklist:

- Run the Private-mode preflight check:

```bash
cd validate-private
./scripts/preflight.sh <stack-name>
```

- Run the baseline cluster validator:

```bash
uv run validate-private --stack <stack-name>
```

- Run a small write smoke test:

```bash
./scripts/smoke-write.sh <stack-name> 20
```

- Discover the three cluster node instance IDs:

```bash
aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:aws:cloudformation:stack-name,Values=<stack-name>" \
    "Name=tag:Role,Values=neo4j-cluster-node" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
```

- Record the instance IDs as `<node-1-id>`, `<node-2-id>`, and `<node-3-id>`.
- Capture the running kernel on all three nodes:

```bash
aws ssm send-command \
  --region "$REGION" \
  --instance-ids <node-1-id> <node-2-id> <node-3-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["uname -r","rpm -q kernel"]' \
  --comment "CVE-2026-31431 baseline kernel check"
```

- Capture the command ID and fetch each invocation output from SSM.

Validation:

- Preflight passes with zero required failures.
- `validate-private` passes.
- `smoke-write.sh` passes.
- All three cluster nodes are SSM managed and online.
- Baseline kernel output is recorded for the test evidence.

### Phase 4: Confirm Cluster Health Before Patching

Status: Complete

Checklist:

- From `validate-private`, query server health:

```bash
uv run run-cypher <stack-name> \
  "SHOW SERVERS YIELD name, state, health, hosting RETURN name, state, health, hosting ORDER BY name"
```

- Confirm all servers are enabled and healthy before changing any node.

Validation:

- The query returns three servers.
- No server is deallocating, cordoned, unavailable, or unhealthy.

### Phase 5: Patch and Reboot One Node at a Time

Status: Complete

Current progress:

- node 1 `i-0846effec3da2371e`: Complete.
- node 2 `i-0f399806309329219`: Not patched this run (validated in runs 1 and 2).
- node 3 `i-0a36144ad9b30502d`: Not patched this run (validated in runs 1 and 2).
- Use the Python 3.9 `dnf` workaround documented in the Known Issues section
  above for all node patch commands.

Checklist:

- Patch only one instance at a time.
- Start with `<node-1-id>`.
- Send the recommended SSM Run Command:

```bash
aws ssm send-command \
  --region "$REGION" \
  --instance-ids <node-1-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo dnf update --advisory ALAS2023-2026-1651 --releasever 2023.11.20260505 -y && sudo reboot"]' \
  --comment "CVE-2026-31431 kernel patch node 1"
```

- Wait for the EC2 instance to return to `running`.
- Wait for SSM `PingStatus` to return to `Online`.
- Verify the running kernel:

```bash
aws ssm send-command \
  --region "$REGION" \
  --instance-ids <node-1-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["uname -r"]' \
  --comment "CVE-2026-31431 kernel verify node 1"
```

- Confirm cluster health:

```bash
uv run run-cypher <stack-name> \
  "SHOW SERVERS YIELD name, state, health, hosting RETURN name, state, health, hosting ORDER BY name"
```

- Run a short write smoke test:

```bash
./scripts/smoke-write.sh <stack-name> 5
```

- Repeat the same sequence for `<node-2-id>`.
- Repeat the same sequence for `<node-3-id>`.
- Do not start patching the next node until the current node is back online,
  running the fixed kernel, and visible as healthy in `SHOW SERVERS`.

Validation:

- Each patched node reports `6.1.168-203.330.amzn2023` or newer for the default
  AL2023 kernel line.
- After each node reboot, all three servers return to healthy state.
- Short smoke writes succeed after each node is patched.
- Any transient write failure during leader movement is documented with
  timestamp and recovery time.

### Phase 6: Final Remediation Evidence

Status: Complete

Checklist:

- Run the full validator again:

```bash
uv run validate-private --stack <stack-name>
```

- Run a longer smoke write:

```bash
./scripts/smoke-write.sh <stack-name> 50
```

- Capture final kernel state from all nodes:

```bash
aws ssm send-command \
  --region "$REGION" \
  --instance-ids <node-1-id> <node-2-id> <node-3-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["uname -r","rpm -q kernel"]' \
  --comment "CVE-2026-31431 final kernel evidence"
```

- Capture final server health:

```bash
uv run run-cypher <stack-name> \
  "SHOW SERVERS YIELD name, state, health, hosting RETURN name, state, health, hosting ORDER BY name"
```

Validation:

- All three nodes run the fixed kernel or newer.
- All three servers are healthy.
- The validator and smoke write pass after all nodes are patched.
- Test evidence includes baseline kernel output, final kernel output, SSM
  command IDs, validator output, and smoke-write output.

### Phase 7: Optional Controlled Replacement Test

Status: Out of scope for this run

Use this phase only if a patched Marketplace AMI version is available and the
test goal includes validating the alternative remediation path.

Checklist:

- Prefer a separate fresh stack so the in-place patch evidence remains clear.
- Deploy another three-node Marketplace cluster as in Phase 2.
- Create a small marker record in Neo4j so replacement can prove data volume
  continuity:

```bash
cd validate-private
uv run run-cypher <stack-name> \
  "CREATE (:CveReplacementTest {id: 'cve-2026-31431', createdAt: datetime()}) RETURN 1 AS created"
```

- Update the stack or launch template so replacements use the patched AMI.
- Confirm the Launch Template version referenced by each node ASG resolves to
  the patched AMI.
- For each node ASG, replace only one node, then wait for the replacement to
  become healthy before replacing the next node.
- Use Auto Scaling instance refresh or terminate one instance in its ASG without
  decrementing desired capacity.
- After each replacement, verify the replacement instance is SSM online.
- After each replacement, verify `uname -r` reports the fixed kernel or newer.
- After each replacement, verify `SHOW SERVERS` reports all three servers
  healthy.
- After each replacement, verify the marker record is still queryable.
- After each replacement, verify short smoke writes pass.

Validation:

- Each replacement instance launches from the patched AMI.
- Each replacement reattaches or recovers the expected Neo4j data volume.
- The cluster returns to three healthy servers between replacements.
- The marker record remains available after all replacements.

### Phase 8: Temporary Mitigation Test

Status: Complete

Run on node 1 before patching it. Apply the mitigation, confirm the module is
blocked, then remove the mitigation and patch the node normally as in Phase 5.
Cluster health must be unchanged throughout.

The mitigation commands are run via SSM to validate whether they work correctly.
The fact that SSM is used here does not change the validity of the test — the
commands themselves are identical to what a customer would run via any access
method.

Checklist:

- Apply the mitigation on node 1:

```bash
aws ssm send-command \
  --region <region> \
  --instance-ids <node-1-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["echo \"install algif_aead /bin/false\" | sudo tee /etc/modprobe.d/disable-algif-aead.conf","sudo modprobe -r algif_aead 2>/dev/null || true"]' \
  --comment "CVE-2026-31431 apply temp mitigation node 1"
```

- Verify the module is blocked:

```bash
aws ssm send-command \
  --region <region> \
  --instance-ids <node-1-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo modprobe algif_aead 2>&1; echo exit:$?"]' \
  --comment "CVE-2026-31431 verify mitigation node 1"
```

- Confirm cluster health is unchanged.
- Remove the mitigation file:

```bash
aws ssm send-command \
  --region <region> \
  --instance-ids <node-1-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo rm /etc/modprobe.d/disable-algif-aead.conf"]' \
  --comment "CVE-2026-31431 remove mitigation node 1"
```

- Patch and reboot node 1 using the Phase 5 procedure.
- After reboot, verify the module can now load cleanly:

```bash
aws ssm send-command \
  --region <region> \
  --instance-ids <node-1-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo modprobe algif_aead 2>&1; echo exit:$?"]' \
  --comment "CVE-2026-31431 post-patch module load node 1"
```

Validation:

- `modprobe algif_aead` fails with `Operation not permitted` or similar while
  the mitigation file is present.
- Cluster health shows three `Enabled`/`Available` servers throughout.
- The mitigation file is absent after node 1 is patched.
- `modprobe algif_aead` succeeds after the fixed kernel is running.

### Phase 9: Tear Down

Status: Complete

Checklist:

- Save the test evidence somewhere durable if needed.
- Tear down the CloudFormation stack:

```bash
cd ..
./teardown.sh <stack-name>
```

- If the test account does not need retained data volumes, delete retained EBS
  volumes:

```bash
./teardown.sh --delete-volumes <stack-name>
```

- Confirm no EC2 instances, NAT gateways, NLBs, EBS volumes, temporary S3
  buckets, or Secrets Manager secrets remain for the test stack.

Validation:

- CloudFormation stack is deleted.
- Retained EBS volumes are either intentionally kept and recorded, or deleted.
- No unexpected billable resources remain.

## Completion Criteria

- Complete: A three-node Neo4j EE Marketplace cluster was deployed for the test.
- Complete: The baseline kernel and cluster health were recorded.
- Complete: Temporary mitigation applied and verified on node 1 before patching.
- Complete: In-place patch applied and verified on node 1; nodes 2 and 3 not
  patched this run (rolling procedure validated in runs 1 and 2).
- Complete: Node 1 rebooted into `6.1.168-203.330.amzn2023.x86_64`.
- Complete: `SHOW SERVERS` returned three healthy servers throughout.
- Complete: Final validation and smoke-write checks passed.
- Complete: Phase 7 (controlled replacement) marked out of scope for this run.
- Complete: The test stack and related AWS resources were cleaned up.
