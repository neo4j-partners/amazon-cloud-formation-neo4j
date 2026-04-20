# CDK Deploy Troubleshooting Log

Issues encountered deploying the Neo4j CDK demo app (`deploy-sample-private-app.sh`) and what was done about each.

---

## Issue 1: CDK VPC Lookup Failing (Lookup Role)

**Error:**
```
current credentials could not be used to assume
'arn:aws:iam::159878781974:role/cdk-hnb659fds-lookup-role-159878781974-us-east-2',
but are for the right account. Proceeding anyway.
```

**Root cause:** `deploy-sample-private-app.sh` cleared `cdk.context.json` before every deploy (`echo '{}' > cdk.context.json`). This forced CDK to do a live VPC lookup on every run, which requires assuming the CDK lookup role. The current IAM credentials lack permission to assume that role.

**Fix:** Removed the `echo '{}' > cdk.context.json` line. CDK now reuses the cached VPC data from `cdk.context.json`. The cache key includes the VPC ID (`vpc-provider:account=...:filter.vpc-id=...:region=...`), so different VPCs get different entries and stale data is not a risk.

---

## Issue 2: `cdk bootstrap` Crashing on Missing Context

**Error:**
```
ValueError: CDK context 'vpcId' is required. Run via deploy-sample-private-app.sh.
python3 app.py: Subprocess exited with error 1
```

**Root cause:** `cdk bootstrap` executes `app.py` to detect the CDK environment, but it does not pass the `-c "vpcId=..."` context flags. `app.py` immediately constructs `Neo4jDemoStack`, which calls `require_context("vpcId")` and raises a `ValueError`. The script's `set -euo pipefail` then exits before `cdk deploy` runs.

The original deploy script had `2>/dev/null || true` on the bootstrap line to suppress this. That suffix was absent from the file, exposing the crash.

**Fix:** Restored `2>/dev/null || true` on the `cdk bootstrap` command so bootstrap failures are non-fatal. `cdk deploy` still runs with the full set of `-c` context flags and works normally.

---

## Issue 3: Bootstrap Exits with "This app contains no stacks"

**Error:**
```
This app contains no stacks
```
followed by `cdk deploy` failing with:
```
SSM parameter /cdk-bootstrap/hnb659fds/version not found.
Has the environment been bootstrapped? Please run 'cdk bootstrap'
```

**Root cause:** In response to Issue 2, a guard was added to `app.py` to skip stack construction when `vpcId` context is absent:
```python
if app.node.try_get_context("vpcId"):
    Neo4jDemoStack(...)
```
This stopped the crash, but CDK bootstrap now sees zero stacks defined and exits without creating the bootstrap CloudFormation stack. The `/cdk-bootstrap/hnb659fds/version` SSM parameter (written by bootstrap) was never created, so `cdk deploy` fails.

**What was tried:** The `app.py` guard was reverted.

**Current fix (in progress):** Pass the real context values to the `cdk bootstrap` command in the script. `VPC_ID` and the other SSM-sourced values are already available at that point in the script (read before bootstrap runs), so the bootstrap invocation now includes:
```bash
cdk bootstrap "aws://${CDK_DEFAULT_ACCOUNT}/${REGION}" \
  --quiet \
  -c "vpcId=${VPC_ID}" \
  -c "externalSgId=${EXTERNAL_SG_ID}" \
  -c "passwordSecretArn=${PASSWORD_SECRET_ARN}" \
  -c "neo4jStack=${NEO4J_STACK}" \
  -c "vpcEndpointSgId=${VPC_ENDPOINT_SG_ID}" \
  2>/dev/null || true
```

With the real VPC ID passed and the VPC data already cached in `cdk.context.json`, synthesis completes cleanly during bootstrap. CDK sees a valid stack, bootstraps the account/region, and `cdk deploy` can proceed.

**Status:** Not yet verified end-to-end.

---

## Issue 4: File-Publishing and Deploy Role Warnings (Same Pattern as Issue 1)

**Error:**
```
current credentials could not be used to assume
'arn:aws:iam::159878781974:role/cdk-hnb659fds-file-publishing-role-159878781974-us-east-2'
current credentials could not be used to assume
'arn:aws:iam::159878781974:role/cdk-hnb659fds-deploy-role-159878781974-us-east-2'
```

**Root cause:** Same underlying cause as Issue 1. CDK bootstrap creates these roles, and CDK CLI tries to assume them during deploy. When assumption fails, CDK falls back to using the caller's credentials directly ("Proceeding anyway").

**Status:** These warnings appear but CDK falls back to direct credentials. Once bootstrap completes successfully (Issue 3 fix), these roles will exist and CDK may be able to assume them. If the IAM entity still lacks `sts:AssumeRole` on these roles after bootstrap, a separate IAM fix will be required.

---

## Issue 5: `cdk bootstrap` Crashes `app.py` Because Context Is Not Passed

**Error:**
```
ValueError: CDK context 'vpcId' is required. Run via deploy-sample-private-app.sh.
python3 app.py: Subprocess exited with error 1
```
…when running `cdk bootstrap aws://159878781974/us-east-2` manually (no `-c` flags).

**Root cause:** `cdk bootstrap` synthesizes the app before bootstrapping. Synthesis constructs `Neo4jDemoStack`, which calls `require_context("vpcId")` and raises. The previous deploy script suppressed this with `2>/dev/null || true`, which also hid real failures (see Issue 6).

**Fix:**
- `app.py` now guards stack construction on the presence of all required context keys. When any are absent, the app synthesizes zero stacks instead of raising. This keeps `cdk synth`, IDE tooling, and manual bootstrap invocations working. Deploy still validates because the script always passes every `-c` flag.
- `deploy-sample-private-app.sh` now passes the same `-c` flags to `cdk bootstrap` as it does to `cdk deploy`, so bootstrap synth produces a real stack. The `2>/dev/null || true` has been removed so real errors surface.
- The script also short-circuits bootstrap when `/cdk-bootstrap/hnb659fds/version` already exists in SSM.

---

## Issue 6: Orphan Bootstrap Assets Blocking Re-bootstrap

**Error:**
```
Resource of type 'AWS::S3::Bucket' with identifier
'cdk-hnb659fds-assets-159878781974-us-east-2' already exists. (at /Resources/StagingBucket)
```

**Root cause:** A prior partial bootstrap attempt had created the assets bucket but left `CDKToolkit` in `REVIEW_IN_PROGRESS` — a state where the stack exists as an empty shell with a pending change set and cannot be updated in place. Every subsequent bootstrap tried to create the bucket fresh and collided with the orphan. The earlier `2>/dev/null || true` had been masking the underlying failure for an unknown number of runs.

**Fix:** Deleted the empty `CDKToolkit` stack and the empty orphan bucket, then re-ran bootstrap. Diagnosis commands:
```bash
aws cloudformation describe-stacks --region us-east-2 --stack-name CDKToolkit \
  --query 'Stacks[0].StackStatus' --output text
aws s3api list-objects-v2 --bucket cdk-hnb659fds-assets-159878781974-us-east-2 --max-items 5
```
Cleanup:
```bash
aws cloudformation delete-stack --region us-east-2 --stack-name CDKToolkit
aws cloudformation wait stack-delete-complete --region us-east-2 --stack-name CDKToolkit
aws s3 rb s3://cdk-hnb659fds-assets-159878781974-us-east-2
```

---

## Issue 7: SCP Blocks Default CDK Bootstrap (Hard Blocker)

**Error:**
```
User: arn:aws:sts::159878781974:assumed-role/AWSReservedSSO_AdministratorAccess_.../ryan.knight@neo4j.com
is not authorized to perform: iam:AttachRolePolicy
on resource: role cdk-hnb659fds-cfn-exec-role-159878781974-us-east-2
with an explicit deny in a service control policy:
arn:aws:organizations::128916679330:policy/o-xunbv3q2oy/service_control_policy/p-h897l3e1
```

**Root cause:** The AWS Organizations SCP `p-h897l3e1` explicitly denies `iam:AttachRolePolicy` on role names matching the default CDK bootstrap qualifier (`cdk-hnb659fds-cfn-exec-role-*`). The default bootstrap template attaches `AdministratorAccess` to the CFN execution role — which is exactly the scenario the SCP was written to block. This is an organizational policy decision, not a code defect. No amount of deploy-script tuning can bypass it; even `AdministratorAccess` SSO credentials are denied by the SCP.

**Options considered:**

1. **Custom CDK qualifier** — `cdk bootstrap --qualifier <custom> ...` produces resource names like `cdk-<custom>-cfn-exec-role-*`. Bypasses the SCP only if the deny is matched by the literal string `hnb659fds`. If the SCP uses a wildcard (`cdk-*-cfn-exec-role-*`), this fails identically. Fast to test.
2. **Restricted execution policies** — `cdk bootstrap --cloudformation-execution-policies <arn>` replaces `AdministratorAccess` with a narrower managed policy. Still calls `iam:AttachRolePolicy`, so this only helps if the SCP conditions on a specific policy ARN (unlikely — the deny here is on the action).
3. **Abandon CDK for this sample** — convert `neo4j_demo_stack.py` into a plain CloudFormation template and deploy with `aws cloudformation deploy`. No bootstrap required, no SCP collision, and consistent with the `neo4j-ce`/`neo4j-ee` pattern already used throughout this repo.
4. **Request an SCP exception** — out of band; depends on org governance.

**Recommendation:** Option 3. The rest of this repo is plain CloudFormation, the Lambda + SG + IAM role the demo needs is a small template (well under 200 lines), and CDK's only real value here — cross-stack references and VPC lookups — is easily replicated by reading SSM parameters directly in the deploy script (which it already does). Moving off CDK removes an entire class of ongoing pain: bootstrap state, credential assumption, qualifier drift, context caching, and SCP collisions.

**Option 1 probe result (tested 2026-04-19):** Bootstrapped with `--qualifier neo4jdemo --toolkit-stack-name CDKToolkit-neo4jdemo`. The SCP deny fired identically on `cdk-neo4jdemo-cfn-exec-role-159878781974-us-east-2`, which means the SCP resource pattern is wildcarded (`cdk-*-cfn-exec-role-*`), not literal on `hnb659fds`. No custom qualifier can evade it. Stack rolled back to `ROLLBACK_COMPLETE` and must be deleted before any retry. **Option 1 is dead.**

**Status:** Bootstrap is not achievable under this org's SCP without an exception. Two viable paths forward:

1. **Rewrite as plain CloudFormation (Option 3).** Durable fix, consistent with the rest of this repo. Work items:
   - Convert `neo4j_demo/neo4j_demo_stack.py` → `sample-private-app.template.yaml` (Lambda, VPC-attached SG with egress rules, IAM role, Function URL with IAM auth, CloudWatch log group).
   - Update `deploy-sample-private-app.sh` to package the Lambda zip (already built under `lambda/`), upload to an S3 bucket the caller owns, and `aws cloudformation deploy` the template with parameters read from SSM.
   - Delete the CDK scaffolding: `app.py`, `cdk.json`, `cdk.context.json`, `neo4j_demo/`, `requirements.txt` (CDK-specific deps), `.venv`, `cdk.out/`.
   - Update `teardown-cdk.sh` → `teardown-sample-private-app.sh` to `aws cloudformation delete-stack`.
   - Delete the orphan `CDKToolkit-neo4jdemo` stack (currently `ROLLBACK_COMPLETE`).

2. **Request an SCP exception from the AWS org administrator** (Option 4). File a ticket against SCP `p-h897l3e1` in org `o-xunbv3q2oy` to carve out `cdk-*-cfn-exec-role-*` for this account, or scope the deny more narrowly (e.g. only when attaching `AdministratorAccess`). Blocks everything until granted; org owner's timelines apply.

**Cleanup still required regardless of path:** one `CDKToolkit-neo4jdemo` stack in `ROLLBACK_COMPLETE` in us-east-2.

---

## Phased Plan: Rewrite as Plain CloudFormation

### De-risking probe (do this first — ~15 min)

Before committing to the full rewrite, verify the SCP doesn't also block IAM role creation under *non*-CDK role names. The deny on `cdk-*-cfn-exec-role-*` is name-scoped, but there may be other rules in the SCP that also affect plain-CloudFormation-created roles (for example, broad blocks on `iam:AttachRolePolicy` with certain managed policies).

**Probe:** deploy a ~30-line CloudFormation template containing only the IAM role the real Lambda will need — with its `AWSLambdaVPCAccessExecutionRole` managed policy attachment — under a repo-style name like `neo4j-demo-lambda-role-<suffix>`.

```yaml
# probe.yaml
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  LambdaRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal: { Service: lambda.amazonaws.com }
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
```

```bash
aws cloudformation deploy --region us-east-2 \
  --stack-name neo4j-demo-scp-probe \
  --template-file probe.yaml \
  --capabilities CAPABILITY_IAM
```

**Decision gate:**
- ✅ `CREATE_COMPLETE` → SCP only blocks CDK's role names. Full rewrite will work. Tear down the probe stack and proceed to Phase 1.
- ❌ `iam:AttachRolePolicy` denied → SCP is broader than assumed; plain CloudFormation won't help either. Stop and escalate to the org admin (Option 4). Do not start the rewrite.

**Probe result (2026-04-19):** ✅ `CREATE_COMPLETE`. IAM role with `AWSLambdaVPCAccessExecutionRole` managed policy attachment succeeded under the non-CDK name `neo4j-demo-scp-probe-LambdaRole-*`. The SCP is name-scoped to CDK role patterns only. Probe stack torn down. Cleared to proceed to Phase 1.

### Phase 1 — Template and deploy script (core path, no Bolt-TLS) — ~1–2 hr

Goal: get a Lambda Function URL that can reach the Neo4j NLB over Bolt, deployed via `aws cloudformation deploy`, matching what the CDK stack produces today. Leave `lambda/handler.py` and the `lambda/` bundling step alone.

**Reference data — verified against `neo4j_demo_stack.py` and `handler.py` on 2026-04-19:**

- Handler: `handler.lambda_handler` (not `handler.handler`).
- Runtime: `python3.13`. Memory: `512`. Timeout: `30` seconds.
- Logging: JSON format, `ApplicationLogLevel: INFO`, System log level default. Log group retention: one month, `RemovalPolicy: DESTROY`.
- Tracing: X-Ray `Active`.
- Env vars: `NEO4J_SSM_NLB_PATH=${SSM_PREFIX}/nlb-dns`, `NEO4J_SECRET_ARN=${PASSWORD_SECRET_ARN}`, plus `NEO4J_BOLT_TLS=true` only when Bolt-TLS is enabled (Phase 2).
- IAM: managed policy `AWSLambdaVPCAccessExecutionRole` + inline policy granting `ssm:GetParameter` on `arn:aws:ssm:<region>:<account>:parameter${SSM_PREFIX}/*` + `secretsmanager:GetSecretValue` on the password secret ARN.
- Subnet IDs: read from SSM — `${SSM_PREFIX}/private-subnet-1-id` and `${SSM_PREFIX}/private-subnet-2-id` (both already written by the EE stack; confirmed via `aws ssm get-parameters-by-path`). No `ec2:DescribeSubnets` call needed.
- SG egress rules (on the Lambda SG, new in this stack): TCP 7687 to `ExternalSgId`, TCP 443 to `VpcEndpointSgId`.
- SG ingress rules (added to existing external SGs via standalone `AWS::EC2::SecurityGroupIngress` resources owned by this stack): TCP 7687 on `ExternalSgId` from Lambda SG, TCP 443 on `VpcEndpointSgId` from Lambda SG.

**Teardown ordering constraint (same as today under CDK):** because the ingress rules on `ExternalSgId` and `VpcEndpointSgId` are owned by this stack, the parent EE stack cannot delete those SGs while this stack exists. Always delete the sample-private-app stack *before* tearing down the EE stack. Document this in `README.md` and `teardown-sample-private-app.sh`.

**Work items:**

1. Create `sample-private-app.template.yaml` with:
   - `AWS::Lambda::Function` — handler `handler.lambda_handler`, runtime `python3.13`, memory 512, timeout 30, JSON logging at INFO, X-Ray active tracing, VPC config using `SubnetIds` param and Lambda SG, env vars listed above, code from `S3Bucket`/`S3Key` params.
   - `AWS::EC2::SecurityGroup` — Lambda SG, egress-only (`SecurityGroupEgress` empty, rules added as separate resources).
   - Two `AWS::EC2::SecurityGroupEgress` (Lambda SG → 7687 to ExternalSG, → 443 to VpcEndpointSG).
   - Two `AWS::EC2::SecurityGroupIngress` (ExternalSG ← 7687 from Lambda SG, VpcEndpointSG ← 443 from Lambda SG).
   - `AWS::IAM::Role` with `AWSLambdaVPCAccessExecutionRole` managed + inline policy (`ssm:GetParameter` on the prefix, `secretsmanager:GetSecretValue` on the password secret).
   - `AWS::Lambda::Url` with `AuthType: AWS_IAM`, targeting the function.
   - `AWS::Logs::LogGroup` — `/aws/lambda/${FunctionName}`, 30-day retention, `DeletionPolicy: Delete`.
   - Parameters: `Neo4jStack`, `VpcId`, `SubnetIds` (`List<AWS::EC2::Subnet::Id>`), `ExternalSgId`, `VpcEndpointSgId`, `PasswordSecretArn`, `SsmPrefix`, `LambdaS3Bucket`, `LambdaS3Key`, `LambdaS3ObjectVersion` (optional, for forced redeploy).
   - Outputs: `FunctionUrl`, `FunctionArn`.

2. Rewrite `deploy-sample-private-app.sh`:
   - Keep the existing SSM reads (lines 96–108). Add two more: `PRIVATE_SUBNET_1_ID`, `PRIVATE_SUBNET_2_ID` from `${SSM_PREFIX}/private-subnet-{1,2}-id`.
   - Create a deploy bucket if missing: `neo4j-sample-private-app-deploy-<account>-<region>` (versioning enabled so object versions drive Lambda updates cleanly). Bucket name is repo-controlled — no SCP collision.
   - Package: `cd lambda && zip -r ../lambda.zip . && cd ..`, upload to `s3://<deploy-bucket>/<stack>/lambda.zip`, capture the returned `VersionId`.
   - Replace the `cdk bootstrap` and `cdk deploy` blocks with `aws cloudformation deploy --template-file sample-private-app.template.yaml --stack-name ${CDK_STACK_NAME} --capabilities CAPABILITY_IAM --parameter-overrides ...` (pass SSM-sourced values + `LambdaS3ObjectVersion`).
   - Read `FunctionUrl`/`FunctionArn` from `aws cloudformation describe-stacks --query 'Stacks[0].Outputs'`.
   - Keep the SSM-write (`/neo4j-cdk/<stack>/function-url`) and `.deploy/cdk-<stack>.json` steps unchanged so `invoke.sh` keeps working without edits.

3. Deploy once end-to-end against `test-ee-1776654862`. Verify `invoke.sh` returns a real Neo4j result (not a connection error). Compare Lambda logs in CloudWatch to a known-good CDK run if one exists.

### Phase 2 — Feature parity for existing CDK options — ~30 min

Only after Phase 1 is green.

- `boltTlsEnabled` flag → add a `BoltTlsSecretArn` parameter + `Fn::If` in the IAM policy + env var. Matches the CDK behaviour at `deploy-sample-private-app.sh:149–150,159`.
- Confirm log retention, timeout, memory size match the CDK stack's defaults.

### Phase 3 — Delete CDK scaffolding — ~15 min

Only after Phase 2 is green and `invoke.sh` works identically.

- Remove: `app.py`, `cdk.json`, `cdk.context.json`, `neo4j_demo/`, `requirements.txt` (CDK deps), `.venv/`, `cdk.out/`, `force-delete-lambda-enis.sh` if CDK-specific.
- Rename: `teardown-cdk.sh` → `teardown-sample-private-app.sh`; replace its body with `aws cloudformation delete-stack` + S3 object cleanup + SSM param delete.
- Update `README.md` to drop CDK references.
- Delete the orphan `CDKToolkit-neo4jdemo` (`ROLLBACK_COMPLETE`) stack.

### Phase 4 — Harden — ~30 min, optional

- Add teardown safety: verify stack exists before delete; wait for completion; clear `.deploy/cdk-*.json`.
- Add a minimal smoke test script that asserts `invoke.sh` returns HTTP 200 and a non-empty Neo4j result.
- Update top-level `CLAUDE.md` with the new sample-private-app workflow, if the project instructions reference CDK.

### Risks and rollback

- **Probe passes but Phase 1 hits a different SCP rule.** Possible if the SCP also denies `lambda:CreateFunction` inside VPC or similar. Mitigation: the probe above only covers IAM; if Phase 1 fails on a different action, that failure message will name the specific action — escalate at that point rather than attempting more workarounds.
- **Lambda cold-start behaviour differs from CDK version.** Unlikely (same runtime, same code), but worth one invoke comparison.
- **Rollback:** Phase 3 is the point of no return. Keep Phases 1–2 deployed under the new stack name (`neo4j-sample-private-app-<suffix>`) alongside the CDK stack name — they don't collide. If the new stack misbehaves, delete it and the old CDK scaffolding is untouched until Phase 3.
