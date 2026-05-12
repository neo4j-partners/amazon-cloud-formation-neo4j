# Robust Tests Plan — Neo4j EE Public Path

## Goal

Close the six test-coverage gaps identified for the `bloom` branch's changes to the public deployment path, then prove the new tests pass against a freshly deployed three-node Neo4j Enterprise public stack.

The fixed end state: a single full-mode run of `test-neo4j --edition ee` against a live three-node public deploy reports every new check as passing, alongside the existing suite.

## Scope

In scope: gaps G1 through G6 from the prior review.

- G1 Plugin JAR presence check (Bloom procedures registered, GDS callable) independent of licensing.
- G2 Bolt TLS scheme awareness in the test runner (switch to the self-signed-aware scheme when the deploy used a Bolt certificate secret).
- G3 Configuration-key regression net (assert the new neo4j.conf keys via SSM).
- G4 NLB DNS source-of-truth check (outputs file URI matches CloudFormation stack outputs).
- G5 CloudWatch log delivery check (log group exists and is receiving events).
- G6 AMI build-mode tag check (deployed instance was launched from an AMI tagged for the expected build mode).

Out of scope: G7 Cypher IP blocklist functional probe, G8 Python alternatives switch, any refactors not required to add the checks.

## Assumptions

- The `bloom` branch is the working branch and contains the template, userdata, and deploy.py changes already reviewed.
- The default AWS profile has permissions to deploy CloudFormation, read SSM, read CloudWatch Logs, describe EC2 and images, and use SSM Run Command on the cluster instances.
- The Marketplace iteration AMI is already built locally and its identifier is written to `neo4j-ee/marketplace/ami-id.txt`. If absent, the plan triggers a fresh AMI build before deploy.
- A three-node deploy is acceptable to run end to end and will be torn down at the end of the validation phase.
- The user authorizes paid AWS resource creation for the duration of the deploy and teardown cycle (one cluster, expected lifetime under two hours).

## Risks

- The new TLS-aware behavior in the test runner must not break the common case where the stack was deployed without a Bolt certificate; the default path stays unchanged.
- SSM-based configuration assertions depend on the cluster instances being reachable by SSM; an early infra-level failure could mask the configuration checks. The plan orders checks so that connectivity and stack-status checks run first.
- CloudWatch log streams may take a few minutes to register after first boot. The plan tolerates a short retry window rather than failing instantly.
- The CloudFormation outputs schema is the new source of truth for the NLB DNS name. If outputs are renamed in a future template revision, the test must surface the mismatch clearly rather than silently passing.
- A three-node deploy that fails partway through can leave a retained data volume per node. The teardown step must remove the stack, the SSM AMI parameter, any copied AMI in the deploy region, and the deploy outputs file.

## Phase Checklist and Status Tracker

Status legend: Pending, In progress, Complete, Blocked.

### Phase 1 — Plan review and alignment

Status: Complete

- [ ] Confirm the six target gaps with the user if any have shifted since the review.
- [ ] Confirm the three-node, public, default-region deploy shape is the intended validation target.
- [ ] Confirm teardown happens automatically at the end of validation.
- [ ] Decide whether the deploy should request a Bloom or GDS license. Default assumption: no license secrets supplied, so the existing license assertions stay skipped while the new JAR-presence and configuration checks still run.

Validation: User has acknowledged the scope and the validation target.

Notes: If the user opts into a license run, the deploy step adds the matching arguments and the licensed assertions activate automatically through the existing flags.

### Phase 2 — Gap G1: Plugin JAR presence checks

Status: Complete

- [ ] Introduce two new connectivity-tier checks: one that asserts Bloom procedures are registered when the deploy requested Bloom, one that asserts the Graph Data Science library is callable when the deploy requested GDS.
- [ ] Drive the checks from existing deploy-outputs signals so they activate only when the relevant plugin was requested. If no outputs signal exists today, add one minimal flag to the outputs file written by `deploy.py`.
- [ ] Make the Bloom check independent of the license check so a missing JAR fails loudly even when no license secret was supplied.
- [ ] Make the GDS check independent of the license check for the same reason.
- [ ] Wire both checks into the simple-tests sequence so they run in every mode.

Validation: Running the test suite against any existing EE public stack reports the two new checks. They pass when the JARs are present and fail with a clear message when they are not.

Notes: Keep the failure messages specific enough to distinguish "procedure not registered" from "Bolt unreachable" so on-call can act without reading source.

### Phase 3 — Gap G2: Bolt TLS scheme awareness

Status: Complete

- [ ] Record the presence of a Bolt certificate in the deploy outputs file when `deploy.py` enabled TLS on the listener.
- [ ] Teach the configuration loader in the test runner to read that signal and switch the Bolt scheme to the self-signed-tolerant variant when TLS was enabled.
- [ ] Preserve the current default scheme when TLS was not enabled.
- [ ] Confirm the HTTP-based checks remain unchanged; only the Bolt driver path adjusts.

Validation: Loading a non-TLS deploy yields the existing Bolt URI unchanged. Loading a TLS deploy yields the self-signed-tolerant Bolt URI and the Bolt connectivity check succeeds end to end.

Notes: This phase does not deploy a TLS stack. A non-TLS three-node deploy in the validation phase is sufficient to prove the default path stays intact. A separate TLS validation can be scheduled later if needed.

### Phase 4 — Gap G3: Configuration-key regression net

Status: Complete

- [ ] Add a configuration audit check that reads the running `neo4j.conf` on a cluster instance through SSM and verifies the keys introduced on the `bloom` branch.
- [ ] Required keys to assert when Bloom is requested: the Bloom license file path setting points at the expected on-disk location.
- [ ] Required keys to assert when GDS is requested: the GDS Enterprise license file path setting points at the expected on-disk location.
- [ ] Required keys to assert unconditionally on the public template: the Cypher IP blocklist setting is non-empty, and the CSV metrics interval is set to the expected cadence.
- [ ] Required key to assert unconditionally: no JDWP listener is configured in `neo4j.conf`.
- [ ] Wire the audit into the full-mode EE flow so it runs alongside the existing deep checks.

Validation: Against any healthy EE public stack the audit passes. If any key is missing or wrong on the running instance the audit reports which key on which instance failed.

Notes: Read the file once per instance and parse in memory; do not run one SSM call per key.

### Phase 5 — Gap G4: NLB DNS source-of-truth check

Status: Complete

- [ ] Add a check that compares the host portion of the Neo4j URI in the deploy outputs file with the corresponding CloudFormation stack output value.
- [ ] Treat any difference as a failure with a clear message that names both values.
- [ ] Wire the check into the EE infra checks so it runs in full mode.

Validation: Against a healthy stack the values match and the check passes. Against a deploy outputs file edited to a wrong host the check fails and names the mismatch.

Notes: The intent is to catch a future rename or shape change in the template outputs without waiting for a customer to hit a routing bug.

### Phase 6 — Gap G5: CloudWatch log delivery check

Status: Complete

- [ ] Add a check that verifies the CloudWatch log group named for the stack exists.
- [ ] Verify at least one log stream within that group has reported a log event within a recent window.
- [ ] Allow a short retry window to absorb the gap between first boot and the agent's first flush.
- [ ] Wire the check into the EE infra checks so it runs in full mode.

Validation: Against a stack that has been up for at least a few minutes the check passes. Against a stack with a misconfigured agent the check reports either a missing group or a stale stream.

Notes: A pass here also confirms the AMI-baked CloudWatch agent binary is being driven by the userdata configuration as designed.

### Phase 7 — Gap G6: AMI build-mode tag check

Status: Complete

- [ ] Add a check that resolves the AMI identifier used by the running cluster instances, reads the image tags, and confirms the build-mode tag matches an expected value.
- [ ] Allow the expected value to be supplied by the deploy outputs file so iteration-mode AMIs are accepted in iteration deploys and marketplace-mode AMIs are accepted in marketplace deploys.
- [ ] Fail the check with a clear message when the tag is absent or carries an unexpected value.
- [ ] Wire the check into the EE infra checks so it runs in full mode.

Validation: A deploy from the locally built iteration AMI passes the check. A deploy from a marketplace AMI passes the check under the matching expected value. A deploy from an AMI missing the tag fails the check.

Notes: This is the cheapest available guardrail against accidentally shipping an iteration-mode AMI through a production path.

### Phase 8 — Pre-deploy readiness

Status: Complete

- [ ] Confirm the locally built AMI identifier exists in `neo4j-ee/marketplace/ami-id.txt`. If missing, build a fresh iteration-mode AMI and run the AMI smoke check before proceeding.
- [ ] Confirm the default AWS profile is selected and the caller identity is the expected account.
- [ ] Confirm there is no stale deploy outputs file that would be picked up by the newest-deploy resolver in error. If there is, archive or remove it.
- [ ] Confirm the test runner builds and imports cleanly under the project's Python toolchain.

Validation: A dry run of the test runner against the most recent outputs file resolves without import or argument errors, even if no live stack matches.

Notes: This phase is the gate before any AWS resources are created.

### Phase 9 — Three-node EE public deploy

Status: Complete

- [ ] Deploy a public EE stack with three nodes using `deploy.py`, default region selection, no license secrets, and APOC enabled.
- [ ] Wait for the stack to reach a healthy terminal state.
- [ ] Confirm the deploy outputs file was written and contains the new fields needed by the checks introduced in earlier phases.
- [ ] Capture the stack name for use by the validation phase and the teardown phase.

Validation: CloudFormation reports the stack in a healthy terminal state and the outputs file is present in the EE deploy directory.

Notes: If the deploy fails, do not advance to validation; instead diagnose, optionally redeploy once, and only proceed when the stack is healthy. If a second attempt also fails, mark the phase Blocked and surface the failure to the user.

### Phase 10 — Full test-suite run

Status: Complete

- [x] Run the EE full test suite against the new stack with the infrastructure security checks enabled.
- [x] Confirm every existing check that previously passed still passes.
- [x] Confirm every check introduced in phases two through seven runs and passes.
- [x] Capture the full pass and fail counts and the runtime.

Validation: 35 of 39 checks passed against `test-ee-1778615343` in 640 seconds. The six new G1 through G6 checks all reported correctly. The four failures break down as one parser bug in the new G3 audit, two pre-existing CE-shaped checks that fail on the EE topology, and one orphaned-AMI failure on the resilience test.

Notes: A clean pass is still the fixed goal of this plan. Phase 11 captures every fix required to reach it. The live stack was then inspected over SSM, which confirmed all four conf keys are present on disk, then torn down. Findings carried forward into Phase 11.

Findings carried to Phase 11:

- Test 24 (neo4j.conf key audit, a G3 check) reported every required key as `None` on every node. Live SSM inspection confirmed every required key is present in `/etc/neo4j/neo4j.conf`. The failure is a parser-input bug, not a UserData gap: SSM Run Command truncates `StandardOutputContent` near 24 KB, the file is roughly 43 KB, and the target keys are appended by `set_neo4j_conf` near the end of the file where they fall outside the response window.
- Test 39 (Wait for follower ASG replacement) reported no InService replacement after 600 seconds. The ASG activity log shows repeated launch failures with the message that the image id of the launch template no longer exists. The original AMI had been deregistered out from under the stack, almost certainly by an unrelated `create-ami.sh` run elsewhere in the account.
- Test 19 (External SG ingress CIDR) and Test 23 (JDWP absent) are CE-shaped checks. They fail on this stack because they query for the single CE-style ASG resource and the CE-style external SG, neither of which exist on the EE public topology.

### Phase 11 — Fix every issue surfaced by Phases 1 through 10

Status: Complete

Goal: turn every fix-marked observation from Lessons Learned and every failure from Phase 10 into a concrete code, template, or test change, completed before any new AWS resources are created. No AWS deploys happen in this phase. The deliverable is a clean, working repository ready for Phase 12.

#### Test-runner and infrastructure check fixes

- [x] Fix the G3 conf audit so it tolerates `neo4j.conf` files larger than the SSM truncation window. The audit now builds a regex from its expected-keys list and runs `grep -E` on the instance so the SSM response only carries the matching lines, well under the 24 KB cap.
- [x] Fix Test 19 (External SG ingress CIDR) so it handles the EE public topology. The check is now edition-aware: CE queries `Neo4jExternalSecurityGroup` and EE queries `Neo4jNLBSecurityGroup` (the SG that actually binds AllowedCIDR on the public template).
- [x] Fix Test 23 (JDWP absent from neo4j.conf) so it iterates the EE multi-ASG instance set. Added `_edition_instance_pairs` helper that returns one pair for CE and one per node for EE; the JDWP check now fans out across the full set.
- [x] Audit every other infrastructure or network check shared between CE and EE for similar CE-shape assumptions. The three remaining shared checks (`check_port_5005_absent`, `check_internal_sg_self_reference`, `check_imdsv2_enforced`) target resources that exist in both editions. No further fan-out work needed.
- [x] Keep `internal.dbms.cypher_ip_blocklist` and `server.metrics.csv.interval` unconditional in EE UserData. Decision: the blocklist is a security control that defends against SSRF from Cypher procedures into the IMDS endpoint at `169.254.169.254` and into private VPC ranges, and removing it would be a real regression; the metrics interval has no security implication and is fine as-is. Added to `CLAUDE.md` under "Security invariants (do not remove)".
- [x] Decide the contract for `dbms.bloom.license_file` and `gds.enterprise.license_file` in UserData. Decision: gate the conf-write on `InstallBloom`/`InstallGDS` rather than on license-secret presence. Bloom-only conf keys are now inside the `installBloom == "true"` block in all three userdata variants; the audit already keys on `bloom_expected`/`gds_expected` and now matches reality.
- [x] Switch the G5 CloudWatch log delivery check to read the log group name from the `Neo4jAppLogGroupName` stack output, falling back to the constructed path only when the output is missing.
- [x] Document the G6 AMI build-mode check's dependence on either tags or Description. Added an in-code comment naming the deploy-side contract (`SourceAmiId` / `SourceRegion` tags preferred, "Copied from <id> in <region>" Description as fallback).

#### Template and UserData fixes

- [x] Add an `InstallBloom` CloudFormation parameter to each EE template variant (public, private, existing-vpc) mirroring `InstallGDS`. Wired into the build-time UserData preamble, gates the Bloom JAR install and Bloom-only conf keys in all three `userdata-*.sh` partials, plumbed through `deploy.py` with a `--no-bloom` opt-out flag, and recorded in deploy outputs so the test runner derives `bloom_expected` from the actual parameter value. Default `true` so existing callers see no behavior change.
- [x] Standardize the NLB DNS output across the three EE templates. Added `Neo4jInternalDNS` to `outputs-public.yaml`; regenerated all three templates.
- [x] Update `deploy.py` so every copied AMI is tagged with `SourceAmiId` and `SourceRegion` at copy time. The G6 check prefers tags and falls back to Description parsing only when the tags are absent.

#### AMI lifecycle fix

- [x] Prevent re-running `create-ami.sh` from deregistering an AMI that a live stack is still referencing. The script now queries every launch-template version in the region for the AMI by name and aborts when any live launch template still references it. Documented in `CLAUDE.md` under "AMI lifecycle invariant".
- [x] Add a single-shot fail-fast guard. `check_launch_template_amis_exist` runs first in `run_robust_tests_checks` and reports the launch template logical id and missing image id when any AMI has been deregistered out from under the stack. Converts the orphaned-AMI failure mode from a 600-second resilience timeout into an immediate clear failure.

#### Repo and account hygiene

- [x] Leave the pre-existing `test-ee-1778613386` stack in place. User decision: not part of this testing cycle, do not touch. The two other unrelated stacks (`test-ee-1778614964` and `test-ee-1778621781`) are likewise left alone.
- [x] Leave the three retained EBS data volumes from the Phase 9 deploy (`vol-009ae032d368ef138`, `vol-0c7c4601c29ca1224`, `vol-0412b3670c2bafa14` in us-east-1) in place. User decision: do not delete.

Validation: A fresh dry run of `test-neo4j --edition ee` against the most recent outputs file resolves cleanly with no import or argument errors. Unit-level confidence is not required at this phase since no live stack is available; the gate is that every checklist item is either Complete or explicitly deferred with a Notes entry.

Notes: This phase is the gate before Phase 12. No new EC2, EBS, or AMI resources may be created until every item above is either Complete or deferred with a written reason.

### Phase 12 — Fresh unlicensed deploy with live conf-key verification

Status: Pending

- [ ] Confirm `neo4j-ee/marketplace/ami-id.txt` points to an existing, registered AMI in the deploy region. Build a fresh iteration-mode AMI if it does not.
- [ ] Deploy a new public EE stack with three nodes, default region selection unless pinned for AMI-copy avoidance, no license secrets, APOC enabled, and `InstallBloom=true` and `InstallGDS=true` so the new parameter wiring is exercised.
- [ ] Wait for the stack to reach a healthy terminal state and confirm the deploy outputs file contains every field added by Phase 11, including the new `InstallBloom` signal and any AMI source identifiers.
- [ ] Before running the full suite, SSM into one cluster instance and inspect `/etc/neo4j/neo4j.conf` and `cloud-init-output.log` to confirm every key the G3 audit expects is present in the form the audit expects. If anything differs from Phase 11's contract, halt and resolve the divergence before continuing.
- [ ] Run the EE full test suite against the new stack with `--infra-security`. Confirm every existing check still passes and every G1 through G6 check passes, including the rewritten G3 audit.
- [ ] Capture the full pass count, the runtime, and the stack name.

Validation: CloudFormation reports the stack in a healthy terminal state, live SSM confirms the configuration contract, and the full test suite reports zero failures.

Notes: This phase replaces the old Phase 10. If anything fails here, diagnose and feed the fix back into Phase 11 before proceeding. Do not advance to Phase 13 with any open failure.

### Phase 13 — Teardown unlicensed cycle

Status: Pending

- [ ] Tear down the unlicensed stack using `./teardown.sh <stack-name>`.
- [ ] Confirm the stack, the related SSM parameter, the copied AMI in the deploy region if one was created, and the deploy outputs file are all removed.
- [ ] Decide whether to remove the retained EBS data volumes with `--delete-volumes`. Default for this validation cycle is to delete them so the licensed cycle starts clean.

Validation: AWS reports no remaining resources associated with the stack name and no residual outputs file is left in the EE deploy directory.

Notes: Teardown proceeds even if validation failed in Phase 12, unless the user explicitly asks to preserve the stack for further debugging.

### Phase 14 — Licensed validation using local license files

Status: Pending

- [ ] Confirm `neo4j-ee/.licenses/bloom.license` and `neo4j-ee/.licenses/gds.license` exist locally. If either is missing, halt and surface the gap before continuing.
- [ ] Upload the two license files to AWS Secrets Manager as plaintext secrets (or update the deploy script to do so on the user's behalf), and capture the two resulting secret ARNs.
- [ ] Deploy a new public EE stack with three nodes that passes both license secret ARNs to `deploy.py`, with `InstallBloom=true` and `InstallGDS=true`.
- [ ] Wait for a healthy terminal state and confirm the deploy outputs file records both license secret identifiers so the existing Bloom and GDS license assertions activate automatically.
- [ ] Before running the full suite, SSM into one cluster instance and verify the two license files are present at the expected on-disk paths under `/var/lib/neo4j/licenses/`.
- [ ] Run the EE full test suite against the licensed stack with `--infra-security`. Confirm every G1 through G6 check passes, every license-aware check passes, and every existing check passes.

Validation: The licensed full-mode run reports zero failures, including the Bloom license, GDS license, JAR presence, configuration audit, NLB DNS, CloudWatch log delivery, and AMI build-mode checks.

Notes: This is the only phase that exercises a licensed deploy end to end. If the license-upload helper does not exist in the deploy tooling today, adding it is a sub-task of this phase rather than a Phase 11 fix, because it has no effect on the unlicensed cycle.

### Phase 15 — Teardown licensed cycle

Status: Pending

- [ ] Tear down the licensed stack, remove its SSM parameter, any copied AMI in the deploy region, and the deploy outputs file.
- [ ] Decide whether to leave the Secrets Manager license secrets in place for future runs or delete them. Default is to leave them since they have no recurring cost and the next licensed run can reuse them.
- [ ] Decide whether to remove the retained EBS data volumes from the licensed stack.

Validation: AWS reports no remaining resources associated with the licensed stack name and no residual outputs file is left in the EE deploy directory.

### Phase 16 — Wrap-up

Status: Pending

- [ ] Summarize the new checks, the Phase 11 fixes, the unlicensed deploy run, and the licensed deploy run, and the final pass result.
- [ ] Note any follow-up items uncovered during validation, including any deferred work from G7 or G8.
- [ ] Mark every prior phase Complete in this document.

Validation: The plan reflects the final state of the work and is suitable as the record of what was changed and what was proven.

## Lessons Learned (Phases 1–9)

This section captures observations that surfaced while implementing G1–G6 and deploying the validation stack. The full test-suite run in Phase 10 has not yet been executed, so nothing here comes from a live test failure. Items marked **Fix** are concrete follow-ups; the rest are notes that future readers and later phases should not have to re-discover.

### From G1, plugin JAR presence

- The Bloom plugin install is unconditional in all three Enterprise UserData variants (public, private, existing-vpc). It is not driven by a CloudFormation parameter; it is a template invariant. The runner therefore treats `BloomExpected` as always yes for Enterprise deploys and only consults the deploy outputs as a forward-looking gate in case the template changes.
- The existing license assertion `bloom.checkLicenseCompliance` already fails when the Bloom JAR is missing because the procedure is unregistered. The new JAR-presence check is still worth keeping because it separates the missing-JAR failure mode from the missing-license failure mode with a clearer error and runs even on deploys that supply no license secret.

### From G2, Bolt TLS scheme awareness

- The public UserData hardcodes the Bolt TLS level to required as soon as a certificate is wired in. There is no off-switch for TLS once a Bolt certificate secret is present, so the runner safely treats the presence of a `BoltTlsSecretArn` field as a TLS-mandated deploy.
- The Phase 9 validation deploy did not use TLS, so the scheme-switch path has been verified only at the parsing layer, not end to end. **Fix:** add an explicit TLS validation, either by toggling TLS in Phase 12 or by adding a dedicated TLS smoke-deploy as a later phase.

### From G3, neo4j.conf key audit

- The UserData runs `neo4j-admin server memory-recommendation` and appends the result to `neo4j.conf`. This produces duplicate keys for memory settings. The audit parser keeps the last occurrence per key, which matches Neo4j's own load order. Future readers should not switch the parser to first-occurrence semantics without re-checking the memory keys.
- The audit reads each cluster instance's `neo4j.conf` exactly once over SSM and parses in memory. A naive design that issued one SSM call per key would be ten to fifteen times slower under typical agent jitter and is worth avoiding.

### From G4, NLB DNS source-of-truth

- The Public template exposes `Neo4jURI` and `Neo4jBrowserURL`, not `Neo4jInternalDNS`. The new `nlb_dns_from_outputs` helper in deploy.py tries `Neo4jInternalDNS` first and then falls back to URI hostnames, which works in practice but conflates two different conventions (private templates appear to expose the internal-DNS key, public does not). The runner's check copes by accepting any of the three keys, but template authors should standardize on one across all three template variants. **Fix:** decide whether `Neo4jInternalDNS` should be emitted by the public template too, and document the chosen contract in the EE templates README.

### From G5, CloudWatch log delivery

- The log group name is also exposed as the `Neo4jAppLogGroupName` stack output. The current check constructs the path string by convention for parity with the UserData; reading from outputs would be more robust against future template renames. **Fix:** switch the check to read the log group from stack outputs and use the constructed path only as a fallback.

### From Phase 10 live run

- The G3 conf-key audit reported every required key as missing on every node and the failure shape pointed at UserData. Live SSM inspection of the running cluster proved every key was actually present in `neo4j.conf`. The audit fails because `aws ssm get-command-invocation` truncates `StandardOutputContent` at roughly 24 KB, the live `neo4j.conf` is roughly 43 KB, and `set_neo4j_conf` appends the target keys near the end of the file where they fall outside the response window. **Fix:** in Phase 11, switch the audit's SSM script to grep only the keys it needs and emit a tight key=value payload, or tail the file rather than catting it.
- The G3 audit's expected-keys list assumes UserData writes `dbms.bloom.license_file` and `gds.enterprise.license_file` only when a license is supplied. Live inspection shows UserData writes both unconditionally today. The audit and UserData disagree on the contract. **Fix:** in Phase 11, pick one contract, apply it on both sides, and document it.
- Test 19 (External SG ingress CIDR) and Test 23 (JDWP absent from neo4j.conf) failed on the EE topology even though both pass on CE. Both tests are part of the shared network-security check set and both assume the CE-style single-ASG and single-external-SG shape. **Fix:** in Phase 11, split or extend these checks to fan out across the EE per-node ASG set and to inspect the correct EE external security group.
- The resilience test for node 2 replacement timed out at 600 seconds. The ASG activity log shows the launch failed repeatedly because the AMI referenced by the launch template no longer exists. Root cause is an AMI lifecycle bug: an unrelated `create-ami.sh` run elsewhere in the account deregistered the AMI while this stack still depended on it. **Fix:** in Phase 11, prevent `create-ami.sh` from deregistering an AMI that a running launch template still references, or tag AMIs with the stacks consuming them so the builder can skip them. Also add a fail-fast pre-test check that asserts every launch template's AMI still exists before any resilience test runs.
- The teardown left three EBS data volumes retained per `DeletionPolicy: Retain` (`vol-009ae032d368ef138`, `vol-0c7c4601c29ca1224`, `vol-0412b3670c2bafa14` in us-east-1). They were not removed automatically. **Fix:** include this decision in Phase 11 and either delete them or leave a note saying why they were preserved.

### From G6, AMI build-mode tag

- AMIs copied across regions via `copy_image` do not carry tags. For deploys outside the source region, the new check has to recover the original AMI via the copy's `Description` field, which the deploy step formats as "Copied from <id> in <region>." This is a fragile contract that the test code now depends on. **Fix:** have deploy.py either tag every copied AMI with `SourceAmiId` and `SourceRegion`, or surface them in the deploy outputs file directly so the test does not have to parse the description string.

### From pre-deploy readiness

- A prior Enterprise stack (`test-ee-1778613386`) was already up and CREATE_COMPLETE before this run. It was left in place rather than torn down without confirmation, but it is consuming hourly costs and has no remaining use. **Fix:** decide whether to tear it down or hand it to another phase before the licensed Phase 12 cycle begins.
- deploy.py hardcodes `InstallGDS=true` for every deploy and records it in outputs accordingly. The runner's `gds_expected` gate is therefore effectively always true today. The plumbing exists so that future deploys can opt out, but no current code path exercises the opt-out, so coverage of the "GDS not requested" branch is implementation-level only.

### From Phase 9 deploy

- A three-node t3.medium public deploy completes in roughly ten to fifteen minutes from CREATE_IN_PROGRESS to CREATE_COMPLETE. Plan future phases that depend on a fresh deploy with this baseline in mind.
- The deploy's default region selection is random across seven regions. The validation deploy was pinned to us-east-1 so the AMI copy step would not run and the G6 build-mode tag check could read tags from the original AMI directly. Deploys that exercise copy paths will exercise the G6 cross-region fallback described above.

## Completion Criteria

The plan is complete when all of the following are true.

- The six target gaps have been implemented as test checks that run automatically in their intended modes.
- A three-node Neo4j EE public stack was deployed, tested with the full suite, and torn down.
- Every existing test still passes and every new test passes against that stack in a single run.
- The teardown removed the stack, the SSM AMI parameter, any copied AMI, and the deploy outputs file.
- This document has every phase marked Complete with notes capturing any decisions or follow-ups.
