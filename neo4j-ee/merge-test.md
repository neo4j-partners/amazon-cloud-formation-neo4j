# Merge Test Plan: main into feat/tls-self-signed-ssm-output

## Goal

Prove that the merge of `main` into `feat/tls-self-signed-ssm-output` works end to end on real AWS infrastructure before the branch merges back into `main`.

The primary test is a `./deploy.py --marketplace` deployment. That path is where the two histories collided, and it is the only path whose behavior changed during conflict resolution. The remaining phases confirm that the branch features and the main features still work after the merge.

All commands run from `neo4j-ee/` unless a step says otherwise.

## Status summary (2026-10-22, end of session)

**The merge is not signed off.** Everything that can be tested without a new listing AMI passes. The real Phase 1 (`./deploy.py --marketplace`) is still FAIL because the published listing AMI `ami-0a6984262620899b5` (2025-12-17) predates the current `create-ami.sh`.

| Phase | Result |
|---|---|
| 0 Offline gates | PASS |
| 1 `--marketplace` deploy | FAIL (listing AMI too old). Local-AMI rerun in `385155106615` PASS: preflight, default and release suites, TLS, resilience, teardown |
| 2 Failure paths | 2.1, 2.4, 2.5 PASS. 2.2 and 2.6 BLOCKED on the listing AMI. 2.3 skipped |
| 3 Branch features | 3.1 to 3.5 and 3.7 PASS. 3.6 PASS except an expired Bloom licence file |
| 4 Main-side | 4.1 and 4.2 PASS. 4.3 not run |
| 5 Orphan sweep | PASS in `385155106615`. Recheck of `159878781974` outstanding (SSO expired) |

**Still to do**

1. When the listing carries an AMI newer than 2026-05-15, re-run Phase 1 with `./deploy.py --marketplace --region us-east-1 --no-bloom --no-gds` in `159878781974`, then 2.2 and 2.6. The user submits to the listing by hand in the Marketplace Portal. Check with the lookup in `src/neo4j_ee/amis.py`.
2. Replace the expired `.licenses/bloom.license`, then re-run step 3.6 to confirm the Bloom check.
3. Recheck `159878781974` (`aws sso login --profile default`): no `test-ee-*` stacks, no `/neo4j-ee/test/` parameters, no available test volumes.
4. Optional: CE unit tests (4.1) and `test-cve.md` (4.3).

**Findings to discuss (no code was changed for any of them)**

1. **SSM parameter leak. Fixed and verified live (2026-10-23).** `cleanup()` now deletes `/neo4j-ee/test/<stack>/ami-id` on any exit before `create_stack` returns. Once the stack exists the parameter is kept, because the launch templates resolve the AMI through it. Live results in `385155106615`, `us-east-1`: `--create-private-dns` without a zone and `--cert-arn` that does not cover `--advertised-dns` each printed `Cleaning up SSM parameter ...` and left `/neo4j-ee/test/` unchanged. A successful 1-node Private deploy (`test-ee-1792771376`) kept its parameter, and `teardown.sh --delete-volumes` then deleted it with the stack, secret, certificate and volume. The missing-licence trigger was not run live because local licence files exist. It takes the same `cleanup()` path.
2. **Stack name collision. Documented, not fixed.** The stack name is `test-ee-<unix seconds>`. Two `deploy.py` runs started in the same second get the same stack name and the same SSM path. This happened once when I launched 3.6 and 3.7 together. `docs/LOCAL-TESTING.md` now tells operators to start runs at least a second apart.
3. **Plan error in 3.7. Fixed.** The step 3.7 command now passes `--private-dns-zone neo4j.local`, the zone that contains the default AdvertisedDNS `neo4j-<stack>.neo4j.local`.
4. **Plan error in 4.2. Fixed.** Step 4.2 now runs only `git check-ignore -v .licenses/bloom.license`, so it no longer risks deleting a real licence file.
5. **Elastic IP quota and `create-test-vpc.py` rollback. Rollback fixed and verified live (2026-10-23).** `us-east-1` in `385155106615` is at its EIP limit from other workloads, so `create-test-vpc.py` and a Private stack can still fail there with `AddressLimitExceeded`. The script now records each resource as it creates it and deletes them in reverse order when a later step fails. A live run in `us-east-1` hit `AddressLimitExceeded` on the first EIP. It rolled back the VPC, IGW, six subnets and three route tables, and the account was back to two VPCs and 13 EIPs.
6. **Redirected output. Fixed and verified live (2026-10-23).** Cause confirmed: Python block-buffers stdout when it is a pipe or file. `deploy.py` now calls `sys.stdout.reconfigure(line_buffering=True)` at the start of `main()`. During the live deploy, the redirected log held 10 lines while the stack was still creating.

**Left alone:** stack `test-ee-1792647880` and its `/neo4j-ee/test-ee-1792647880/*` parameters, certificate and secret in `385155106615`. Six older `neo4j-test-ee-17789*.neo4j.local` certificates in `159878781974`. Unassociated EBS volumes and EIP `eipalloc-0c515de1d7598d4fe` in `us-east-1` that predate this work. The `marketplace/ami-id.txt` AMI `ami-0f92649f24792a2a3` and the `ami-0343e14cf79009051` AMI.

## What the merge changed

The merge touched three conflicting files and one auto-merged script. Each row below maps to a test phase.

| Area | Merge result | Tested in |
|---|---|---|
| `--marketplace` AMI lookup | Main's product-code lookup was ported into `src/neo4j_ee/amis.py`. The branch's `resolve_ami` calls it. | Phase 1, Phase 2 |
| SSM parameter in marketplace mode | `--marketplace` now creates `/neo4j-ee/test/<stack>/ami-id` and passes it as the `ImageId` parameter. On the branch it passed nothing and used the template default. | Phase 1, Phase 2 |
| Deployment record | Records now carry `MarketplaceProductCode`, `MarketplaceAmiName`, and `MarketplaceAmiOwner` in marketplace mode. | Phase 1 |
| `--tls` flag | Main still had the old `--tls` flag. The merge removed it because the branch replaced it with `--cert-arn`, `--advertised-dns`, and `--enable-public-tls`. | Phase 3 |
| `install_licenses` | Main's leftover stub was dropped. The branch already moved licence handling into `src/neo4j_ee/licenses.py`. | Phase 3 |
| `smoke-write.sh` | The branch deleted it in favor of `smoke-write.py`. Main's one-line fix to the shell script was not carried over. | Phase 4 |
| `teardown.sh` | Auto-merged. Main's comment change says the SSM parameter is now temporary in both AMI modes. | Phase 1, Phase 5 |
| CE template and `.gitignore` | Taken from main without conflict. | Phase 4 |

## Behavior under test

After the merge, `./deploy.py --marketplace` does the following, in this order:

1. Looks up AMIs owned by `aws-marketplace` that carry the product code `4t4a9h39qkq4tbo3n9zd51p25`, filtered to state `available`.
2. Picks the newest image by `CreationDate`.
3. Writes that AMI id to the SSM parameter `/neo4j-ee/test/<stack>/ami-id`.
4. Passes the SSM path to the stack as the `ImageId` parameter.
5. Uses the repo's own template for the selected mode, not the live Marketplace CloudFormation delivery option.

Evidence that this is the intended behavior:

- Main's `README.md` describes `--marketplace` as resolving the region-local Marketplace AMI by product code.
- Main's `test-cve.md` relies on this behavior to test the newest listing AMI against the repo's Private template.
- The template default for `ImageId` is the pinned path `/aws/service/marketplace/prod-vwigx4rbvvb5s/2026.03.1`. Step 0.5 showed that this path does not exist in account `159878781974` in `us-east-1`, so a deploy that relied on the default would fail at parameter resolution.

Open decision for the branch owner: `docs/LOCAL-TESTING.md` still says `--marketplace` uses the `ImageId` template default, on lines 61 and 78. That text is now wrong. Confirm the merged behavior is the one you want, then update the doc. This plan treats the merged behavior as correct and records the doc drift in the sign-off section.

## Assumptions

- The test runs in a non-production AWS account that is subscribed to the Neo4j EE Marketplace listing.
- `AWS_PROFILE` points at that account. The Marketplace account is `385155106615`.
- The AWS SSO session is current. Run `aws sso login --profile <profile>` first.
- The first deploy targets `us-east-1`, which is the AMI source region for local builds.
- Account `385155106615` publishes the listing, so it may see different images than a customer account. If you have a plain subscribed account, repeat Phase 1 there.
- A local AMI exists at `marketplace/ami-id.txt` for the Phase 3 regression runs.
- Bloom and GDS licence files exist at `.licenses/bloom.license` and `.licenses/gds.license` for step 3.7 only.

## Cost and time

A 3-node Private stack costs about $0.52 per hour in `us-east-1` at on-demand list prices. The estimate comes from the earlier cost review and was not checked against the live price list.

Plan for roughly 15 to 25 minutes per 3-node deploy, plus teardown. Tear down each stack before starting the next phase. The retained EBS data volumes cost about $0.074 per hour in total until deleted, so use `--delete-volumes` on every teardown in this plan.

## Phase 0: Offline gates

These steps cost nothing and must pass before any deploy.

### 0.1 Merge state

```bash
git status --short
git diff --check
grep -rlE '^(<<<<<<<|>>>>>>>) ' . --exclude-dir=.venv --exclude-dir=.git
```

**Expected:** No file is listed as `UU`, `DU`, or `AA`. `git diff --check` prints nothing. The grep prints nothing.

**Status: PASS with one note (2026-10-22).** `git diff --check` printed nothing and the marker grep found no conflict markers. `git status --short` still lists `README.md` and `deploy.py` as `UU`, because the resolved files have not been staged. Run `git add neo4j-ee/README.md neo4j-ee/deploy.py` before committing the merge.

### 0.2 Rendered templates

```bash
(cd templates && python3 build.py --verify)
for t in templates/neo4j-*.template.yaml; do cfn-lint "$t"; done
```

**Expected:** All three templates report `up to date`. `cfn-lint` reports no findings. A pydantic warning about Python 3.14 is harmless.

**Status: PASS (2026-10-22).** `build.py --verify` reported all three templates up to date. `cfn-lint` exited 0 on all three. Its only output was the pydantic warning.

### 0.3 Unit and contract tests

Use the venv that has `boto3`. The system `python3` does not.

```bash
validate-private/.venv/bin/python -m unittest discover -s tests
```

**Expected:** Zero failures and zero errors. The last verified run executed 148 tests with 26 skipped. A different skip count needs an explanation.

**Status: PASS (2026-10-22).** The run executed 148 tests with 26 skipped and reported `OK`. The counts match the last verified run. The marketplace test prints two progress lines to stdout, which is harmless.

### 0.4 Import and CLI surface

```bash
python3 -m py_compile deploy.py src/neo4j_ee/amis.py
./deploy.py --help | grep -E 'marketplace-product-code|cert-arn|enable-public-tls'
./deploy.py --tls --region us-east-1
```

**Expected:** Compilation succeeds. The help output lists `--marketplace-product-code`, `--cert-arn`, and `--enable-public-tls`. The last command exits with an argparse error that names `--tls` as unrecognized, and it creates no AWS resources.

**Status: PASS (2026-10-22).** `py_compile` succeeded for both files. The help output lists `--marketplace-product-code`, `--cert-arn`, and `--enable-public-tls`. `./deploy.py --tls --region us-east-1` exited with code 2 and the message `deploy.py: error: unrecognized arguments: --tls`.

### 0.5 Snapshot the expected AMI

Record what the Marketplace lookup should return. Phase 1 compares against this.

```bash
export AWS_PROFILE=<profile>
aws ec2 describe-images \
  --owners aws-marketplace \
  --filters Name=product-code,Values=4t4a9h39qkq4tbo3n9zd51p25 Name=state,Values=available \
  --region us-east-1 \
  --query 'sort_by(Images,&CreationDate)[-1].[ImageId,Name,OwnerId,CreationDate]' \
  --output text
```

**Expected:** One row with an AMI id, a name, an owner id, and a creation date. Save all four values. If the command returns `None`, the product code is wrong or the listing is not visible to the account. Stop and fix that before continuing. A returned row does not prove the account is subscribed. The Phase 1 instance launch is the real subscription check.

Also record the AMI behind the template default, to know whether the two paths differ:

```bash
aws ssm get-parameter \
  --name /aws/service/marketplace/prod-vwigx4rbvvb5s/2026.03.1 \
  --region us-east-1 --query Parameter.Value --output text
```

**Status: PASS (2026-10-22).** The run used `AWS_PROFILE=default`, which is account `159878781974`. This is not the Marketplace account `385155106615` that the earlier deployments used.

| Value | Result |
|---|---|
| AMI id | `ami-0a6984262620899b5` |
| Name | `neo4jeemp-513a3a85-20f7-4809-bb9f-aab293ce1e1d` |
| Owner id | `679593333241` |
| Creation date | `2025-12-17T00:26:41.000Z` |

Phase 1 must report these four values.

The pinned template default `/aws/service/marketplace/prod-vwigx4rbvvb5s/2026.03.1` returned `ParameterNotFound`. A listing of the `prod-vwigx4rbvvb5s` path shows published versions up to `2025.12.0`, plus aliases such as `latest-calver`. The two paths cannot be compared, because the default does not resolve. A deploy that passes no `ImageId` override would fail, and this is what the branch's `--marketplace` did before the merge. Main's product-code lookup is the only `--marketplace` path that works in this account today.

The newest listing AMI dates from 2025-12-17, which is before the May 2026 CVE fix. Expect Phase 1 to deploy a kernel without that fix.

### 0.6 Region sweep

The lookup is one `describe_images` call against the region you pass in, so the code path is the same everywhere. The risk is a region where the listing is not published or the account is not subscribed. Run the same query in every region that `deploy.py` supports. This costs nothing.

```bash
for r in us-east-1 us-east-2 us-west-2 eu-west-1 eu-central-1 ap-southeast-1 ap-southeast-2; do
  printf '%s ' "$r"
  aws ec2 describe-images --owners aws-marketplace \
    --filters Name=product-code,Values=4t4a9h39qkq4tbo3n9zd51p25 Name=state,Values=available \
    --region "$r" \
    --query 'sort_by(Images,&CreationDate)[-1].[ImageId,Name,CreationDate]' --output text
done
```

**Expected:** Each region prints one row with its own AMI id, because Marketplace AMIs are region-local. The names and creation dates should describe the same release. Save every row.

A region that prints `None` is not a failure of the merge. It means the listing or subscription is missing there. Use such a region for step 2.3. Use a region that printed a row for step 2.6.

**Status: PASS (2026-10-22).** All seven regions returned one row. Every row describes the same release, and each AMI id is region-local. The rows were read in account `159878781974`.

| Region | AMI id | Creation date |
|---|---|---|
| us-east-1 | `ami-0a6984262620899b5` | 2025-12-17T00:26:41Z |
| us-east-2 | `ami-012775f55a0d3e942` | 2025-12-17T00:26:37Z |
| us-west-2 | `ami-04b74124b7df6795c` | 2025-12-17T00:26:37Z |
| eu-west-1 | `ami-0a8b6e4af20adbc21` | 2025-12-17T00:26:35Z |
| eu-central-1 | `ami-0b01cf97d88bbc0a5` | 2025-12-17T00:26:37Z |
| ap-southeast-1 | `ami-0c0bf2ee496fad370` | 2025-12-17T00:26:36Z |
| ap-southeast-2 | `ami-09ac87d6f85c332a9` | 2025-12-17T00:26:34Z |

Every region printed a row, so step 2.3 has no region to use and is skipped. Use `eu-west-1` for step 2.6. The expected AMI id there is `ami-0a8b6e4af20adbc21`.

## Phase 1: Primary test, `./deploy.py --marketplace`

This phase deploys a 3-node Private cluster from the Marketplace AMI. It exercises the ported lookup, the SSM parameter, the deployment record, the self-signed certificate path, and the operator tooling in one run.

### Phase 1 run record

Phase 1 runs in account `159878781974` with `AWS_PROFILE=default`, guarded by `--expected-account 159878781974`.

| Item | Value |
|---|---|
| Stack | `test-ee-1792716760` |
| Region | `us-east-1` |
| Mode and size | Private, 3 nodes, `--no-bloom --no-gds` |
| Console log | `/private/tmp/claude-502/-Users-ryanknight-projects-aws-neo4j-aws-cloudformation/93065428-4930-4740-8e23-d708d2a30715/scratchpad/merge-test-phase1.log` |

**Launched resources so far:**

- SSM parameter `/neo4j-ee/test/test-ee-1792716760/ami-id`.
- Self-signed ACM certificate `arn:aws:acm:us-east-1:159878781974:certificate/1c6314b8-5a92-4e83-82f2-c5eca24684c3`.
- CloudFormation stack `test-ee-1792716760`. It ended in `CREATE_FAILED` with 82 resources `CREATE_COMPLETE` and 3 `CREATE_FAILED`. The three failures are `Neo4jNode1ASG`, `Neo4jNode2ASG`, and `Neo4jNode3ASG`.
- Four EC2 instances, all still running because the stack uses `DisableRollback`:

  | Instance | Role | Type | AMI |
  |---|---|---|---|
  | `i-06ab1ff347923c822` | node-1 | `t3.medium` | `ami-0a6984262620899b5` |
  | `i-0a114f457e91f8f3f` | node-2 | `t3.medium` | `ami-0a6984262620899b5` |
  | `i-0f486a5a22636c935` | node-3 | `t3.medium` | `ami-0a6984262620899b5` |
  | `i-0258c883b2b3c4950` | bastion | `t4g.small` | `ami-07890d146f8d6ee5b` |

- Partial record `.deploy/test-ee-1792716760.failed`. The record stays `.failed` because the stack never completed. It holds `StackName`, `Region`, `DeploymentMode`, `SSMParamPath`, `AutoImportedCertificateArn`, and `StackID`. It has none of the `Marketplace*` fields, which are only written to the final `.txt` record.
- The temporary S3 template bucket was deleted by `cleanup()`. The ACM certificate was not, because the stack still uses it (`ResourceInUseException`). `teardown.sh` removes it from the `.failed` record.

**Baseline for Phase 5:** Seven older SSM parameters already exist under `/neo4j-ee/test/` in this account and region. They are `test-ee-1778912278`, `1778984306`, `1778986767`, `1778986820`, `1778986944`, `1778988352`, and `1778991580`. They predate this plan and were leaks from earlier runs. All seven were deleted by hand before the Phase 1 stack finished, so the Phase 5 SSM check should be empty in `us-east-1` after the last teardown. Other regions were not checked.

**Phase 1 result: FAIL (2026-10-22).** The merged `--marketplace` path did everything the merge changed correctly. The stack then failed because the published Marketplace AMI is incompatible with this branch's templates. The failure is not in the merged code. It does block the merge, because it means `--marketplace` on the merged branch cannot deploy.

| Step | Status | Notes |
|---|---|---|
| 1.1 Deploy | FAIL | The lookup, SSM parameter, banner and certificate steps passed. The stack went to `CREATE_FAILED`. |
| 1.2 Deployment record | Not run | The final `.txt` record is only written on success. The `.failed` record has the right `SSMParamPath` and certificate ARN. |
| 1.3 AWS-side assertions | Partly run | Passed. The SSM parameter and `ResolvedValue` equal the step 0.5 AMI. All three Neo4j nodes run that AMI. The AMI owner, name and product code match step 0.5. |
| 1.4 Preflight | Not run | No working cluster. |
| 1.5 Functional validation | Not run | No working cluster. |
| 1.6 TLS path | Partly run | Passed. The certificate is `IMPORTED` and `ISSUED`, its SAN is `neo4j-test-ee-1792716760.neo4j.local`, and the NLB uses it (`InUseBy` has one entry). |
| 1.7 Resilience | Not run | No working cluster. |
| 1.8 Teardown | Not run | Waiting on a decision. The stack is still running. |

**What passed in step 1.1, against the expected output:**

1. `Resolved Marketplace AMI ami-0a6984262620899b5 in us-east-1 from product code 4t4a9h39qkq4tbo3n9zd51p25.` appeared.
2. `Creating SSM parameter /neo4j-ee/test/test-ee-1792716760/ami-id -> ami-0a6984262620899b5...` appeared.
3. The self-signed certificate import appeared, with the expected SAN.
4. The banner showed `AMI source: marketplace`, the step 0.5 AMI id, the product code, the AMI name, and owner `679593333241`.
5. No `AMI original:` line appeared.
6. Step 6, the stack reaching `CREATE_COMPLETE`, did not happen.

**Root cause:**

1. Each node's UserData ran `cfn-init` and then the bootstrap. The bootstrap stopped at `/opt/neo4j/bin/neo4j-bootstrap.sh: line 360: /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json: No such file or directory`.
2. On the node, `rpm -q amazon-cloudwatch-agent` reports `package amazon-cloudwatch-agent is not installed`, and `/opt/aws/amazon-cloudwatch-agent` does not exist. `aws-cfn-bootstrap` is installed. Neo4j is not installed, and `/var/log/neo4j` does not exist, so the bootstrap never reached the Neo4j install.
3. The branch's four-layer architecture expects the AMI to carry the agent. `marketplace/create-ami.sh` line 190 installs it with `dnf install -y unzip python3.11 jq openssl amazon-cloudwatch-agent aws-cfn-bootstrap`.
4. The published listing AMI was built before that change, on 2025-12-17. It does not carry the agent.
5. Main's old per-topology UserData installed the agent at boot, with `yum install -y amazon-cloudwatch-agent` in `userdata-private.sh`. The old templates therefore worked on the old AMI.

**Consequence:** After this merge, `./deploy.py --marketplace` pairs the new templates with an AMI built for the old templates. It fails on every node. This also affects `test-cve.md`, which relies on `--marketplace`. The incompatibility could affect other AMI contents beyond the agent. Only the first failure was observed, because the bootstrap stops at the first error.

**Decision needed from the branch owner.** Do not change code before this is discussed. Options to consider:

- Rebuild the AMI with the branch's `create-ami.sh` in the Marketplace account and publish it to the listing. Then `--marketplace` works with the new templates.
- Treat `--marketplace` as unsupported on this branch until the listing AMI is rebuilt, and say so in the README and `docs/LOCAL-TESTING.md`.
- Make the bootstrap install the agent when it is missing. This conflicts with the architecture contract, which places OS packages in the AMI layer.

**Stack state:** Torn down with `./teardown.sh --delete-volumes test-ee-1792716760`. The stack, the three retained volumes, the SSM parameter, the `.failed` record and this run's certificate are gone.

**Follow-up work after the failure (2026-10-22):**

1. A new iteration AMI, built from the current `marketplace/create-ami.sh` in account `159878781974`, passed `marketplace/test-ami.sh`. It carries the `neo4j` user (uid and gid 500), the Neo4j yum repo, `python3.11` and the CloudWatch agent. This confirms the old listing AMI is the only gap.
2. `docs/LOCAL-TESTING.md` and `README.md` now describe the product-code lookup, the SSM parameter and the requirement that the listing AMI is built by the current script.
3. `marketplace/create-ami.sh` changes:
   - A build that does not stop within 12 minutes now terminates the builder and exits 1 with a clear message. Before, the script waited about 10 minutes for a silent timeout and left the instance running.
   - `dnf remove -y awscli-2` replaces `dnf remove -y awscli`, which was a no-op on AL2023.
   - `AMI_NAME_SUFFIX` allows a second same-day AMI while the first is still in use by a launch template.
4. `marketplace/test-ami.sh` changes: it asserts `aws` resolves to `/usr/local/bin/aws` and that the `awscli-2` package is absent. The old `rpm -q awscli` check passed vacuously. It also checks openssl, the Neo4j GPG key in the rpm database, `/opt/aws/amazon-cloudwatch-agent/etc`, and findutils and hostname.
5. Validation: the rebuilt AMI `ami-0343e14cf79009051` passes all checks. A build with an injected failing step exited 1 with the new message and left no instance running.
6. An attempt to read the build result from the serial console did not work. `get-console-output` returned nothing, even for a stopped instance. The script therefore uses the timeout, not an in-band failure marker.
7. `test-ami.sh` prints `FAIL: kernel package not installed` in CHECK 5B. The script does not count it, and it predates these changes.

8. `deploy.py --marketplace` now exits before creating anything when the newest listing AMI was created before 2026-05-15 (`MIN_BOOTSTRAP_AMI_DATE` in `src/neo4j_ee/amis.py`). `--allow-old-marketplace-ami` overrides it. Unit tests cover the reject and override paths.

Phase 1 stays FAIL until it is re-run against a listing AMI built by the current script. That needs a human-gated Marketplace submission.

### 1.1 Deploy

```bash
./deploy.py --marketplace --mode Private --region us-east-1 \
  --number-of-servers 3 --no-bloom --no-gds 2>&1 | tee /tmp/merge-test-phase1.log
```

Use `--no-bloom --no-gds` so no licence files are required and the plugin set matches the Marketplace defaults.

**Expected console output, in order:**

1. A line that reads `Resolved Marketplace AMI <ami-id> in us-east-1 from product code 4t4a9h39qkq4tbo3n9zd51p25.`
2. A line that reads `Creating SSM parameter /neo4j-ee/test/<stack>/ami-id -> <ami-id>...`
3. A line about importing a self-signed ACM certificate with the SAN `neo4j-<stack>.neo4j.local`.
4. A banner with `AMI source:     marketplace`, `AMI:` set to the id from step 0.5, `Product code:`, `AMI name:`, and `AMI owner:`.
5. No `AMI original:` line, because no AMI copy happens in marketplace mode.
6. The deploy finishes with the stack in `CREATE_COMPLETE` and prints connection details.

Set the stack name for the remaining steps:

```bash
export STACK=$(ls -t .deploy/*.txt | head -1 | xargs basename | sed 's/\.txt$//')
echo "$STACK"
```

### 1.2 Deployment record

```bash
grep -E '^(AmiSource|AmiId|SSMParamPath|MarketplaceProductCode|MarketplaceAmiName|MarketplaceAmiOwner|AutoImportedCertificateArn|Neo4jTlsSelfSigned|CopiedAmiId|Neo4jBoltUrl|NumberOfServers|InstallBloom|InstallGDS) ' .deploy/$STACK.txt
```

| Field | Expected value |
|---|---|
| `AmiSource` | `marketplace` |
| `AmiId` | The id from step 0.5 |
| `SSMParamPath` | `/neo4j-ee/test/<stack>/ami-id` |
| `MarketplaceProductCode` | `4t4a9h39qkq4tbo3n9zd51p25` |
| `MarketplaceAmiName` | The name from step 0.5 |
| `MarketplaceAmiOwner` | The owner id from step 0.5 |
| `AutoImportedCertificateArn` | An ACM ARN in `us-east-1` |
| `Neo4jTlsSelfSigned` | `true` |
| `CopiedAmiId` | Empty or absent |
| `Neo4jBoltUrl` | Starts with `neo4j+ssc://neo4j-<stack>.neo4j.local:7687` |
| `NumberOfServers` | `3` |
| `InstallBloom` and `InstallGDS` | `false` for both |

### 1.3 AWS-side assertions

Confirm the SSM parameter holds the AMI id:

```bash
aws ssm get-parameter --name /neo4j-ee/test/$STACK/ami-id \
  --region us-east-1 --query Parameter.Value --output text
```

**Expected:** The AMI id from step 0.5.

Confirm the stack received the SSM path and resolved it to the same AMI:

```bash
aws cloudformation describe-stacks --stack-name $STACK --region us-east-1 \
  --query 'Stacks[0].Parameters[?ParameterKey==`ImageId`]'
```

**Expected:** `ParameterValue` is the SSM path and `ResolvedValue` is the AMI id from step 0.5.

Confirm all four instances run that AMI. The cluster has three Neo4j nodes and one bastion.

```bash
aws ec2 describe-instances --region us-east-1 \
  --filters Name=tag:aws:cloudformation:stack-name,Values=$STACK Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceId,ImageId,InstanceType]' --output text
```

**Expected:** The three `t3.medium` Neo4j nodes use the Marketplace AMI. The `t4g.small` bastion uses its own SSM-resolved Amazon Linux image and is not expected to match.

Confirm the Marketplace AMI owner is the AWS Marketplace account:

```bash
aws ec2 describe-images --image-ids <ami-id> --region us-east-1 \
  --query 'Images[0].[OwnerId,Name,ProductCodes]'
```

**Expected:** The owner and name match the record. The product code list contains `4t4a9h39qkq4tbo3n9zd51p25`.

### 1.4 Operator readiness gate

Run from `validate-private/`:

```bash
cd validate-private
uv run preflight $STACK
```

**Expected:** All 11 readiness checks pass. Do not continue on any failure.

### 1.5 Functional validation

```bash
uv run validate-private --stack $STACK
uv run validate-private --stack $STACK --suite release \
  --expected-cypher-default <value for the release under test>
uv run run-cypher $STACK 'CALL dbms.components() YIELD name, versions, edition RETURN name, versions, edition'
uv run run-cypher $STACK 'SHOW SERVERS'
uv run scripts/smoke-write.py $STACK 5
```

**Expected:**

- The default suite passes all groups, including Bolt, edition, memory, APOC, cluster roles, and the conf-key audit for `internal.dbms.cypher_ip_blocklist`.
- The release suite passes.
- `dbms.components()` returns edition `enterprise`.
- `SHOW SERVERS` lists three servers, all `Enabled` and `Available`.
- `smoke-write.py` completes five create and delete cycles. This also confirms the Python replacement works on a stack whose record has no `BoltTlsSecretArn`, which is the case main's shell fix addressed.

### 1.6 TLS path under marketplace mode

The self-signed import runs after the AMI lookup in the merged `main()`. Confirm the two features coexist.

```bash
CERT=$(grep '^AutoImportedCertificateArn' .deploy/$STACK.txt | awk '{print $3}')
aws acm describe-certificate --certificate-arn $CERT --region us-east-1 \
  --query 'Certificate.[Status,Type,DomainName,SubjectAlternativeNames,InUseBy]'
```

**Expected:** The type is `IMPORTED`. The SAN list contains `neo4j-<stack>.neo4j.local`. `InUseBy` lists the NLB listener ARNs.

### 1.7 Resilience spot check

Only run this step if the release gate requires it. Terminate one Neo4j node and wait for the ASG to replace it. The replacement must launch from the same Marketplace AMI, because the launch template references the SSM-resolved AMI id.

**Expected:** `SHOW SERVERS` returns to three `Available` servers within the normal recovery window. The new instance's `ImageId` equals the AMI id from step 0.5.

### 1.8 Teardown

```bash
cd ..
./teardown.sh --delete-volumes $STACK
```

**Expected:**

- The stack reaches `DELETE_COMPLETE`.
- The teardown summary lists the SSM parameter path and deletes it.
- The auto-imported certificate is deleted.
- No `Copied AMI` line appears.
- The retained data volumes are deleted.

Verify the cleanup with these checks:

```bash
aws ssm get-parameter --name /neo4j-ee/test/$STACK/ami-id --region us-east-1
aws acm describe-certificate --certificate-arn $CERT --region us-east-1
```

**Expected:** Both commands fail with a not-found error.

## Phase 2: Marketplace failure paths

These runs confirm that failures in the new lookup leave nothing behind.

### 2.1 Unknown product code

```bash
./deploy.py --marketplace --marketplace-product-code does-not-exist \
  --mode Private --region us-east-1 --no-bloom --no-gds
```

**Expected:**

- The process exits non-zero with the message `Could not find an available AWS Marketplace AMI for product code 'does-not-exist' in us-east-1`.
- No CloudFormation stack is created.
- No SSM parameter exists under `/neo4j-ee/test/`, because the lookup fails before the write.
- No ACM certificate is imported and no licence secret is created, because those steps come after the lookup.
- No temporary template S3 bucket remains.

Verify with:

```bash
aws cloudformation list-stacks --region us-east-1 \
  --query 'StackSummaries[?starts_with(StackName,`test-ee-`) && StackStatus!=`DELETE_COMPLETE`].StackName'
aws ssm describe-parameters --region us-east-1 \
  --parameter-filters Key=Name,Option=BeginsWith,Values=/neo4j-ee/test/ \
  --query 'Parameters[].Name'
```

### 2.2 Explicit valid product code

```bash
./deploy.py --marketplace --marketplace-product-code 4t4a9h39qkq4tbo3n9zd51p25 \
  --mode Private --region us-east-1 --number-of-servers 1 --no-bloom --no-gds
```

**Expected:** The result matches Phase 1 for the AMI, the SSM parameter, and the record fields. A 1-node stack is enough here. Tear it down with `./teardown.sh --delete-volumes` afterward.

### 2.3 Region without a listing or subscription

Use a region that printed `None` in step 0.6. Skip this step if every region printed a row.

```bash
./deploy.py --marketplace --mode Private --region <region-with-no-listing> --no-bloom --no-gds
```

**Expected:** The same clear error as step 2.1, with that region named. No resources remain.

### 2.4 Early failure after the SSM parameter exists

This step measures a known gap. In `main()`, `resolve_ami` creates the SSM parameter first. The partial deployment record is written much later, just before stack creation. The `cleanup()` function in `deploy.py` never deletes the parameter. A failure between those two points leaves a parameter that `teardown.sh` cannot find, because no record exists.

The most likely trigger is a deploy that installs Bloom and GDS by default when no licence files are present. Move any `.licenses/` directory aside, then run the deploy without `--no-bloom --no-gds`:

```bash
mv .licenses .licenses.aside 2>/dev/null
ls -t .deploy | head -1 > /tmp/merge-test-last-record.txt
./deploy.py --marketplace --mode Private --region us-east-1
mv .licenses.aside .licenses 2>/dev/null
```

**Expected:**

- The deploy exits with `InstallBloom=true requires a Bloom licence` before any stack is created.
- No new file appears in `.deploy/`. Compare `ls -t .deploy | head -1` with the value saved above.
- The temporary S3 bucket does not exist yet, so nothing needs cleanup there.

Then check for an orphaned parameter:

```bash
aws ssm describe-parameters --region us-east-1 \
  --parameter-filters Key=Name,Option=BeginsWith,Values=/neo4j-ee/test/ \
  --query 'Parameters[].Name'
```

**Record the result.** Today the expected outcome is that a parameter named for the failed deploy exists, which confirms the leak. This is a baseline measurement and not a pass or fail on the merge, because local mode on the branch leaks the same way. Delete the orphan by hand:

```bash
aws ssm delete-parameter --name /neo4j-ee/test/<failed-stack>/ami-id --region us-east-1
```

Optionally repeat the step with a trigger from the same window, such as `--cert-arn` for a certificate that does not cover `--advertised-dns`. Record whether each trigger leaks.

### 2.5 Late failure after the record exists

This step covers the other side of the gap. After the partial record is written, `teardown.sh` can find and delete the SSM parameter. Force a failure after that point by using ExistingVpc mode with invalid network ids:

```bash
./deploy.py --marketplace --mode ExistingVpc --region us-east-1 \
  --vpc-id vpc-00000000 --subnet-1 subnet-00000000 --subnet-2 subnet-00000001 \
  --subnet-3 subnet-00000002 --private-route-table-1 rtb-00000000 --no-bloom --no-gds
```

**Expected:**

- The deploy fails, either at CloudFormation validation or during stack creation.
- The auto-imported certificate and the temporary S3 bucket are cleaned up by `cleanup()`.
- A partial record in `.deploy/` lists `SSMParamPath`. If no record exists, the failure happened before the record was written. Note that and treat the run as another example of step 2.4.
- `./teardown.sh --delete-volumes <stack>` removes the parameter.

Confirm the parameter is gone after teardown.

### 2.6 Second-region deploy

The code path is the same in every region, so one more region is enough to catch anything region-specific in the full flow. Pick a region that printed a row in step 0.6, such as `eu-west-1`. A 1-node stack keeps the cost low.

```bash
./deploy.py --marketplace --mode Private --region eu-west-1 \
  --number-of-servers 1 --no-bloom --no-gds
```

**Expected:**

- The resolved AMI id differs from the `us-east-1` id and equals the id that step 0.6 printed for `eu-west-1`.
- The record has `Region` set to `eu-west-1`, `AmiSource=marketplace`, the `eu-west-1` AMI id, and the three `Marketplace*` fields.
- The SSM parameter exists in `eu-west-1`, not in `us-east-1`.
- The stack's `ImageId` parameter shows the SSM path and a `ResolvedValue` equal to the `eu-west-1` AMI id.
- `uv run preflight <stack>` and `uv run validate-private --stack <stack>` pass.

Tear down with `./teardown.sh --delete-volumes <stack>`. Confirm the parameter and certificate are gone in `eu-west-1`:

```bash
aws ssm get-parameter --name /neo4j-ee/test/<stack>/ami-id --region eu-west-1
aws acm describe-certificate --certificate-arn <AutoImportedCertificateArn> --region eu-west-1
```

**Expected:** Both commands fail with a not-found error.

## Phase 3: Branch feature regression under the merged code

Each step deploys, validates, and tears down. Use `uv run preflight` and `uv run validate-private` from Phase 1 for every Private or ExistingVpc stack.

### 3.1 Local AMI, Private, 3 nodes, same region

```bash
./deploy.py --mode Private --region us-east-1 --no-bloom --no-gds
```

**Expected:**

- The record has `AmiSource=local`, `SSMParamPath`, and `AmiId` equal to the content of `marketplace/ami-id.txt`.
- The record has no `MarketplaceProductCode`, `MarketplaceAmiName`, or `MarketplaceAmiOwner` fields.
- The banner prints the `AMI:` line and no `Product code:` line.
- Preflight and the default `validate-private` suite pass.

### 3.2 Local AMI, cross-region copy

```bash
./deploy.py --mode Private --region us-east-2 --number-of-servers 1 --no-bloom --no-gds
```

**Expected:**

- The deploy copies the AMI into `us-east-2` and waits for it to become available.
- The record has `CopiedAmiId` and `SourceRegion`.
- The copied AMI carries the tags `SourceAmiId` and `SourceRegion`.
- The banner prints `AMI original:` with the source id.

Run the same command a second time before teardown of the first stack's AMI copy. **Expected:** The second run prints `Reusing existing copied AMI` and does not copy again.

### 3.3 Public mode, default plain TCP

```bash
./deploy.py --mode Public --region us-east-1 --number-of-servers 1 --no-bloom --no-gds
```

**Expected:** The banner prints `TLS:            disabled (plain TCP)`. The Bolt URL uses `bolt://` and no certificate is imported. The record has no `AutoImportedCertificateArn`.

### 3.4 Public mode with a user-supplied certificate

```bash
./deploy.py --mode Public --region us-east-1 --number-of-servers 1 --no-bloom --no-gds \
  --enable-public-tls --cert-arn <acm-arn> --advertised-dns <dns-name>
```

**Expected:**

- The deploy verifies the certificate covers `<dns-name>` before creating the stack.
- The record has no `AutoImportedCertificateArn`.
- After `./teardown.sh --delete-volumes`, the user-supplied certificate still exists in ACM.

Also run the mismatch case with a certificate that does not cover the DNS name. **Expected:** The deploy exits before stack creation with a certificate and DNS mismatch error.

### 3.5 Existing VPC

Use a VPC with three private subnets and a private route table. Take the ids from your test VPC.

```bash
./deploy.py --mode ExistingVpc --region us-east-1 --vpc-id <vpc> \
  --subnet-1 <s1> --subnet-2 <s2> --subnet-3 <s3> --private-route-table-1 <rtb> \
  --no-bloom --no-gds
```

**Expected:** Self-signed TLS applies as in Phase 1. Preflight and `validate-private` pass.

### 3.6 Plugins and licences

With licence files present:

```bash
./deploy.py --mode Private --region us-east-1 --number-of-servers 1
```

**Expected:** Bloom and GDS install. The record lists `AutoCreatedLicenseSecretArns`. After teardown, the auto-created licence secrets are deleted.

Without licence files, run the same command with the `.licenses/` directory moved aside.

**Expected:** The deploy exits early with `InstallBloom=true requires a Bloom licence` before it creates the stack.

### 3.7 Private DNS record

```bash
./deploy.py --mode Private --region us-east-1 --number-of-servers 1 --no-bloom --no-gds \
  --create-private-dns --private-dns-zone neo4j.local
```

**Expected:** The record has `Neo4jPrivateDnsRecord` and `Neo4jPrivateDnsHostedZoneId`. The name resolves from the bastion to the NLB.

## Phase 4: Main-side changes

### 4.1 Community Edition template

```bash
cfn-lint ../neo4j-ce/neo4j.template.yaml
grep -c 'pc:w4wy9u4d8teae0gu2lkwuv7w' ../neo4j-ce/neo4j.template.yaml
grep -c 'pc:4t4a9h39qkq4tbo3n9zd51p25' ../neo4j-ce/neo4j.template.yaml
```

**Expected:** `cfn-lint` is clean. The first count is 9 and the second count is 0. Main moved the CE template to its own product code, and the EE templates must keep the EE product code:

```bash
grep -c 'pc:4t4a9h39qkq4tbo3n9zd51p25' templates/neo4j-private.template.yaml
```

**Expected:** The count is greater than 0.

Run the CE unit tests if the CE environment is available:

```bash
cd ../neo4j-ce && uv run python -m unittest discover -s test_ce
```

### 4.2 Licence files stay out of git

```bash
git check-ignore -v .licenses/bloom.license
```

**Expected:** `git check-ignore` prints the `.gitignore` rule that matches. The check reads the path and does not need the file to exist, so do not `touch` and `rm` it. That would delete a real licence file.

### 4.3 CVE remediation guidance

Main added `CVE-2026-31431-customer-remediation.md` and `test-cve.md`. This merge does not change their content. Run `test-cve.md` as a follow-on only when the CVE guidance is part of the same release. It uses `./deploy.py --mode Private --marketplace --number-of-servers 3`, which is the path Phase 1 validates.

## Phase 5: Orphan sweep

Run after the last teardown. Every command must return an empty result for resources created during this plan.

```bash
aws cloudformation list-stacks --region us-east-1 \
  --query 'StackSummaries[?starts_with(StackName,`test-ee-`) && StackStatus!=`DELETE_COMPLETE`].StackName'
aws ssm describe-parameters --region us-east-1 \
  --parameter-filters Key=Name,Option=BeginsWith,Values=/neo4j-ee/test/ --query 'Parameters[].Name'
aws acm list-certificates --region us-east-1 \
  --query 'CertificateSummaryList[?contains(DomainName,`.neo4j.local`)].CertificateArn'
aws ec2 describe-volumes --region us-east-1 \
  --filters Name=status,Values=available Name=tag:aws:cloudformation:stack-name,Values=test-ee-* \
  --query 'Volumes[].VolumeId'
aws secretsmanager list-secrets --region us-east-1 \
  --query 'SecretList[?contains(Name,`test-ee-`)].Name'
aws ec2 describe-images --owners self --region us-east-2 \
  --filters 'Name=name,Values=neo4j-ee-copy-*' --query 'Images[].ImageId'
```

**Expected:** The first five checks are empty. The last check lists only the `us-east-2` AMI copy from step 3.2. Deregister it and delete its snapshot if you no longer need it.

Repeat the first five checks with `--region` set to the second region from step 2.6, such as `eu-west-1`. **Expected:** All five are empty there too.

## Pass criteria

The merge is safe to complete when all of these hold:

| Gate | Requirement |
|---|---|
| Offline | All Phase 0 steps pass. |
| Primary | Every Phase 1 expectation holds, including the record fields, the `ResolvedValue` match, preflight, and the release suite. |
| Regions | Step 0.6 printed an AMI row for every region you intend to support, and step 2.6 passes in one region other than `us-east-1`. |
| Failure paths | Steps 2.1, 2.2, and 2.5 pass. Step 2.3 passes if a region without a listing exists. The step 2.4 result is recorded. |
| Regression | Steps 3.1, 3.3, and 3.4 pass at minimum. Steps 3.2, 3.5, 3.6, and 3.7 pass or have a recorded reason for skipping. |
| Main-side | Step 4.1 and step 4.2 pass. |
| Cleanup | The Phase 5 sweep is empty. |

Any failure in Phase 1 blocks the merge. A leaked SSM parameter in step 2.4 does not block the merge, because local mode on the branch leaks the same way. Log it as a follow-up.

## Results log

Fill in during the run.

| Step | Date | Stack or command | Result | Notes |
|---|---|---|---|---|
| 0.1 | 2026-10-22 | `git status`, `git diff --check`, marker grep | PASS | No markers. `README.md` and `deploy.py` still `UU` until staged. |
| 0.2 | 2026-10-22 | `build.py --verify`, `cfn-lint` x3 | PASS | All three templates up to date and lint clean. |
| 0.3 | 2026-10-22 | `unittest discover -s tests` | PASS | 148 tests, 26 skipped. |
| 0.4 | 2026-10-22 | `py_compile`, `--help`, `--tls` | PASS | `--tls` rejected with exit code 2. |
| 0.5 | 2026-10-22 | `describe-images`, `ssm get-parameter` | PASS | Account `159878781974`. AMI `ami-0a6984262620899b5`. Template default path not found. |
| 0.6 | 2026-10-22 | Seven-region `describe-images` sweep | PASS | All seven regions returned a row. Step 2.3 skipped. |
| 1.1 | 2026-10-22 | `test-ee-1792716760`, `--marketplace --mode Private`, 3 nodes | FAIL | Stack `CREATE_FAILED`. All three nodes signalled FAILURE. The Marketplace AMI has no `amazon-cloudwatch-agent` and the new bootstrap needs it. |
| 1.2, 1.4, 1.5, 1.7 | 2026-10-22 | | Not run | No working cluster. |
| 1.3, 1.6 | 2026-10-22 | `test-ee-1792716760` | Partly run, pass | SSM parameter, `ResolvedValue`, node AMI ids, AMI product code, and certificate all correct. |
| 1.8 | | | Not run | Stack still running. Awaiting a decision. |
| 1.1 to 1.8 (local-AMI rerun) | 2026-10-22 | `test-ee-1792722574`, account `385155106615`, local AMI `ami-0f92649f24792a2a3`, Private, 3 nodes, `--no-bloom --no-gds` | PASS (listing lookup not tested) | Stack `CREATE_COMPLETE`. Record fields correct for local mode (`AmiSource=local`, SSM path, `Neo4jTlsSelfSigned=true`, `neo4j+ssc://` Bolt URL). SSM parameter and `ResolvedValue` equal the AMI id. All three nodes run the AMI. Cert `IMPORTED`/`ISSUED`, SAN correct, in use by the NLB. `preflight` 12 passed, 0 failed. Default suite 20/20, release suite 26/26 (`--expected-cypher-default CYPHER_25`; Neo4j 2026.10.0, Java 25.0.4.1). `dbms.components()` edition `enterprise`. `SHOW SERVERS` 3 `Enabled`/`Available`. `smoke-write.py` 5/5. Resilience: terminated `i-01e7daf4850d6e493`, three servers `Available` again after about 3.5 minutes, replacement `i-0f4d946f15a4f2653` on the same AMI. Teardown with `--delete-volumes`: stack, SSM parameter, certificate, secret and 3 volumes deleted and verified. Proves merged templates, bootstrap, TLS and operator tooling on the new AMI. Real Phase 1 (`--marketplace`) still FAIL until the listing carries a new AMI. |
| 2.1 | 2026-10-22 | `--marketplace --marketplace-product-code does-not-exist`, account `159878781974` | PASS | Exited with the expected "Could not find an available AWS Marketplace AMI" error naming the code and region. No stack, no SSM parameter under `/neo4j-ee/test/`, no new `.deploy/` record. Only the six older `.neo4j.local` certificates remain. |
| 2.2 | 2026-10-22 | `--marketplace --marketplace-product-code 4t4a9h39qkq4tbo3n9zd51p25`, account `159878781974` | BLOCKED | Exited 1 at the `MIN_BOOTSTRAP_AMI_DATE` guard: listing AMI `ami-0a6984262620899b5` is dated 2025-12-17. Nothing created. This confirms the guard, not the success path. Re-run when the listing carries a new AMI. |
| 2.3 | 2026-10-22 | | SKIPPED | Every region printed a listing row in step 0.6. |
| 2.4 | 2026-10-22 | `--marketplace --allow-old-marketplace-ami`, no `.licenses/`, account `159878781974` | PASS (leak recorded) | Exited with `InstallBloom=true requires a Bloom licence`, no stack, no new `.deploy/` record. The SSM parameter `/neo4j-ee/test/test-ee-1792724216/ami-id` leaked, as predicted. Two more triggers also leaked it (account `385155106615`): `--cert-arn` that does not cover `--advertised-dns` (step 3.4 mismatch case) and `--create-private-dns` without a zone name. Orphans deleted by hand. Follow-up item 2 stands. `.licenses/` restored. |
| 2.5 | 2026-10-22 | `test-ee-1792724228`, `--marketplace --allow-old-marketplace-ami --mode ExistingVpc` with fake ids, account `159878781974` | PASS | Stack `CREATE_FAILED` on the fake VPC id. `cleanup()` removed the certificate and S3 bucket. The `.failed` record listed `SSMParamPath`. `teardown.sh --delete-volumes` removed the SSM parameter, volumes and record. Needed the override flag because the guard fires first. |
| 2.6 | | | BLOCKED | Needs a listing AMI newer than 2026-05-15. |
| 3.1 | 2026-10-22 | Covered by the Phase 1 rerun `test-ee-1792722574` | PASS | `AmiSource=local`, SSM path, `AmiId` equals `marketplace/ami-id.txt`. No `Marketplace*` fields. Banner has an `AMI:` line and no `Product code:` line. Preflight and default suite passed. |
| 3.2 | 2026-10-22 | `test-ee-1792724619` and `test-ee-1792725458`, us-east-2, 1 node, account `385155106615` | PASS | First run copied `ami-0f92649f24792a2a3` to `ami-02e176d9e7afbc789`. Record has `CopiedAmiId` and `SourceRegion`. Copy carries tags `SourceAmiId` and `SourceRegion`. Banner prints `AMI original:`. Second run printed `Reusing existing copied AMI`. Both stacks torn down. AMI copy and snapshot deleted afterward. |
| 3.3 | 2026-10-22 | `test-ee-1792724620`, Public, 1 node | PASS | Banner `TLS: disabled (plain TCP)`. Bolt URL `bolt://`. No `AutoImportedCertificateArn`. Torn down. Assertions only; no functional validation (`validate-private` is for Private stacks). |
| 3.4 | 2026-10-22 | `test-ee-1792726440`, Public with `--enable-public-tls`, self-signed imported cert | PASS | Banner `TLS: enabled`. Record has `CertificateArn` and `AdvertisedDNS`, no `AutoImportedCertificateArn`. The cert survived teardown (`ISSUED`, not in use). Mismatch case (`--advertised-dns other.example.com`) exited 1 before stack creation with the SAN mismatch error, leaking the SSM parameter. The test cert was deleted afterward. |
| 3.5 | 2026-10-22 | `test-ee-1792731067`, ExistingVpc, us-east-2, 1 node, `scripts/create-test-vpc.py` VPC | PASS | Self-signed TLS applied. Preflight 12/12. Default suite 16/16. Stack and test VPC torn down. us-east-1 could not be used: the account is at its Elastic IP quota from other workloads. |
| 3.6 | 2026-10-22 | `test-ee-1792727248`, Private, 1 node, Bloom + GDS | PASS with 1 data failure | `InstallBloom` and `InstallGDS` true. `AutoCreatedLicenseSecretArns` recorded. Preflight 12/12. GDS 2026.10.0 loaded. 17 of 18 checks passed. The Bloom licence check failed because the local `.licenses/bloom.license` expired on 2026-10-21 (`-1 days remaining`). Needs a fresh licence file. Teardown deleted the licence secrets. The missing-licence early exit is the same path as step 2.4. Note: I deleted this stack's SSM parameter by mistake while cleaning an orphan (see Notes), so ASG self-heal was not tested on it. |
| 3.7 | 2026-10-22 | `test-ee-1792729780`, Private, 1 node, `--create-private-dns --private-dns-zone neo4j.local` | PASS | Record has `Neo4jPrivateDnsRecord` and `Neo4jPrivateDnsHostedZoneId`. From the bastion, the name resolves to `10.0.10.207`, the same IP as the NLB DNS name. Preflight 12/12, suite 16/16. The plan's command omits `--private-dns-zone`, which is required. |
| 4.1 to 4.3 | 2026-10-22 | | PASS (4.3 not run) | 4.1: `cfn-lint` clean on the CE template, CE `pc:w4wy...` count 9, CE `pc:4t4a...` count 0, EE private template `pc:4t4a...` count 25. CE unit tests not run. 4.2: `.gitignore:58 neo4j-ee/.licenses/` matches. 4.3 is a follow-on and was not run. |
| 5 | 2026-10-22 | Sweep of us-east-1 and us-east-2, account `385155106615` | PASS | No test stacks (other than `test-ee-1792647880`, which belongs to someone else), no SSM parameters, certificates, secrets, volumes, VPCs or AMI copies left from this run. Unassociated volumes and the unassociated EIP `eipalloc-0c515de1d7598d4fe` predate this run and are not mine. Account `159878781974` was last checked after step 2.5 (clean); its SSO token expired afterward, so a final recheck there is outstanding. |

## Follow-ups after sign-off

1. Done: `docs/LOCAL-TESTING.md` already describes the product-code lookup and the SSM parameter in marketplace mode. It now also documents the stack name collision.
2. Done in code: the SSM leak fix in `cleanup()`. Land it in a separate commit after the merge, and verify it against AWS with the three triggers listed in finding 1.
3. Done: the stale `.gitignore` comment that mentioned `deploy.sh --tls`.
4. Commit the merge. Keep the uncommitted `CLAUDE.md` edit out of the merge commit.
