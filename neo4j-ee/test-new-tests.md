# Test plan: new TLS audit tests

This plan covers how to test the TLS verification work added in this branch:

1. `validate-private` TLS suite: `run_tls_checks` and `--suite tls`
2. `preflight` TLS-params readiness check (`_tls_params_set`)
3. `sample-private-app` Lambda TLS conformance probe and its deploy-time gate
4. The supporting build-time contract tests and rendered-template changes

The core risk with verification code is that it passes vacuously: a check that
always reports PASS is worse than no check. Every section below therefore has a
positive test (passes on a correct stack) and a negative test (fails when the
property is actually broken). A check you have not watched fail is not yet
trusted.

---

## Execution progress (live)

Run started 2026-05-16, account 159878781974, region us-east-1, full plan.

| Phase | Status | Result |
|---|---|---|
| 0 Static checks | COMPLETE | 8/8 PASS |
| 1 Live positive | COMPLETE on `test-ee-1778986767` | preflight 12/12; --suite tls 10/10 (after 3rd check bug found+fixed, below); default **22/22** all PASS |
| 2 sample-private-app probe | COMPLETE | PRODUCT DEFECT FIXED by Bolt-only NLB-DNS advertise; routed Lambda resolves routing table, demo + tls_probe both PASS |
| 3 Negative tests | COMPLETE on `test-ee-1778986767` | 3d FAIL+exit1→PASS; 3c FAIL(exact policy)→PASS; 3b per-node TLS-conf FAIL w/ offending keys (self-heal replaced perturbed node = detection + correct self-heal proven); 3a covered-by-analysis (user-approved skip; same restart path as 3b) |
| 4 Topology coverage | PARTIAL | Public-refusal VERIFIED; ExistingVpc / single-node / release gate pending |
| Teardown | PENDING | |

CRITICAL kill-loop fix (between Phase 2 and resuming Phase 3): the default
Private TLS NLB 7473 target group used an HTTPS health check; the NLB checker
sends no SNI, Jetty `sniHostCheck` answers `400 Invalid SNI`, so the target
is permanently ELB-unhealthy and the `HealthCheckType=ELB` node ASGs replace
every instance ~20 min (grace) after launch. User-approved Option 1: 7473
health check → TCP in `networking-{private,existing-vpc,public}.yaml` (public
TLS branch only; public plain-TCP keeps HTTP L7). build --verify clean, 94
tests OK, cfn-lint clean on all 4 templates.

Option 1 fix VALIDATED live on `test-ee-1778986767` (a CREATE_COMPLETE
Private TLS stack built with the fixed template; the prior assumption that
`test-ee-1778984306` was deleted was wrong, it was a stale `rtk proxy`
read, so reads now use direct `aws`): `get-template` shows the 7473 TG
`HealthCheckProtocol: TCP`; all 3 instances `healthy` in
`test-ee-1778986767-https-tg` (was permanently unhealthy in the loop);
each node ASG has exactly one scaling activity (the original launch), zero
ELB-system-health terminations, instances stable >25 min past the 1200 s
grace. Kill loop resolved.

3rd check bug (found by Phase 1 on the fixed stack, user-approved fix):
`validate-private/src/validate_private/checks.py` `_audit_..._target_group`
asserted the 7473 health check must be `HTTPS` and labelled success
`"7473 HTTPS L7, 7687 TCP"` — the **old kill-loop expectation, inverted**.
As written it PASSes a kill-loop stack and FAILs a correctly-fixed one.
Fixed: assert 7473 `HealthCheckProtocol == "TCP"` (HTTPS now means the
kill-loop bug is present), success detail `"7473 TCP, 7687 TCP"`, with the
sniHostCheck/no-SNI/`HealthCheckType=ELB` rationale comment matching the
three networking YAMLs and the `test_template_partials.py` contract test.
After the fix, `uv run validate-private --stack test-ee-1778986767
--suite tls` = **all 10 PASSED** (preflight 12/12 unchanged).

What needed fixing (done): Bug 1 `HTTPS reachable on 7473` curled the raw NLB
hostname (Jetty sniHostCheck -> 400); now forces SNI=AdvertisedDNS via
`curl --resolve`. Bug 2 `AdvertisedDNS resolves in-VPC` hard-failed on the
default `CreatePrivateDns=false` deploy; now gated on the new
`StackConfig.create_private_dns` and strengthened to assert alias-to-NLB
when the stack owns the DNS. Files: `validate-private/src/validate_private/
{checks,config}.py`. 94 unit tests still pass.

Product defect fix (Phase 2): the TLS branch of
`templates/src/partials/configure-tls.sh` advertised the synthetic,
in-VPC-unresolvable `AdvertisedDNS` for the Bolt routing table, so routed
`neo4j+ssc://` clients (the documented 3-node mode) could not resolve the
routing table. Fix: `server.bolt.advertised_address` now advertises the
always-in-VPC-resolvable `${loadBalancerDNSName}:7687` (Bolt has no Jetty
`sniHostCheck`). `server.default_advertised_address` deliberately stays
`${advertisedDNS}` (it is Jetty's no-SNI fallback host for the HTTPS 7473
path). Test + AD-4 doc updated to match; build + 94 unit tests + cfn-lint
green. Two false-alarm `000`/`Sandbox.Timedout` symptoms during re-test were
post-deploy readiness flakes, not defects (see lessons in audit). Detailed
timeline + lessons learned in `test-new-tests-audit.md`.

---

## Phase 0: Static checks (no AWS account)

**Status: COMPLETE — all 8 checks PASS (run 2026-05-16).**

These run anywhere and gate every later phase.

- [x] `cd neo4j-ee && python -m unittest discover -s tests` — 94 tests pass (`Ran 94 tests OK`)
- [x] `cd neo4j-ee/templates && python build.py --verify` — all three templates up to date
- [x] `cfn-lint templates/neo4j-private.template.yaml templates/neo4j-private-existing-vpc.template.yaml templates/neo4j-public.template.yaml` — clean (exit 0)
- [x] `cfn-lint sample-private-app/sample-private-app.template.yaml` — clean (exit 0)
- [x] `python -m py_compile` on the changed Python files compiles (exit 0)
- [x] `cd neo4j-ee/validate-private && uv run python -c "import validate_private.checks, validate_private.cli, validate_private.config"` imports cleanly (`imports OK`)
- [x] `StackConfig` has `advertised_dns` and `certificate_arn` fields (both `True`)
- [x] `validate-private --help` lists `tls` under `--suite` (`--suite {release,tls,failover,resilience,all}`)

What to look for: a stale committed template is the most common failure here.
If `build.py --verify` fails, a partial was edited without regenerating. Run
`python build.py` and recommit both.

**Phase 0 result summary:** Every static gate is green. Unit suite is 94/94.
Committed templates are byte-identical to a fresh build (no stale partial). Both
template families lint clean. All six changed Python files compile and the
`validate_private` package imports without error. The new `StackConfig` TLS
fields and the `tls` suite choice are present in the runtime surface. The only
console noise is an unrelated `samtranslator` Pydantic-V1-on-Python-3.14
`UserWarning` emitted by cfn-lint; it does not affect lint results (exit 0) and
is environmental, not introduced by this branch.

**Nothing to fix from Phase 0.** Cleared to proceed to the live phases.

---

## Phase 1: Live stack, positive path

Deploy a real Private stack. TLS is mandatory there, so a clean stack must pass
every TLS check.

```bash
cd neo4j-ee
./deploy.py --region us-east-1            # Private, 3-node, self-signed ACM cert
cd validate-private
uv run preflight
uv run validate-private --suite tls
uv run validate-private                  # default run now also includes the TLS audit
```

**Status: COMPLETE on stack `test-ee-1778972234` (Private, 3-node).
Run 1 found 2 real check bugs (exit 1). Both fixed (user-approved). Run 2:
`--suite tls` exit 0, all 10 PASS. Default run confirmed below.**

### preflight

- [x] The line `TLS params set: CertificateArn, AdvertisedDNS` reports PASS
      (`AdvertisedDNS=neo4j-test-ee-1778972234.neo4j.local`)
- [x] Required check count is 12 (plus 1 informational), matching the README
      (`12 passed, 0 failed`, +1 `[INFO]`)

### validate-private --suite tls

- [x] `NLB TLS listeners` PASS — `7473/7687 TLS with ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`
- [x] `NLB target-group health checks` PASS — `7473 HTTPS L7, 7687 TCP`
- [x] `HTTPS reachable on 7473` PASS (after fix) —
      `GET https://neo4j-test-ee-1778972234.neo4j.local:7473/ (SNI ...) -> 200`.
      Run 1 was FAIL/400; Bug 1 fixed (see Phase 1 findings).
- [x] `Plaintext HTTP 7474 refused` PASS — `no plaintext HTTP listener on 7474`
- [x] `Bolt 7687 requires TLS` PASS — `TLS handshake on 7687 returned a server certificate`
- [x] `Served cert identity matches AdvertisedDNS` PASS —
      `cert subject/SAN contains neo4j-test-ee-1778972234.neo4j.local`
- [x] `AdvertisedDNS resolves in-VPC` PASS (after fix) — skip-pass with
      stated reason: synthetic cert SAN, `CreatePrivateDns` not set, clients
      use `neo4j+ssc://<nlb-dns>`. Run 1 was FAIL; Bug 2 fixed (see Phase 1
      findings). Stack-owned-DNS branch covered in Phase 4 ExistingVpc.
- [x] One `TLS conf (<instance-id>)` line per cluster node, all PASS
      (3 nodes, all `TLS conf enforced (bolt REQUIRED, https on, http off)`)
- [x] Exit code is 0 — Run 2 `--suite tls` exit 0, all 10 PASS; default
      `validate-private` exit 0, **All 22 tests PASSED** (118.4s), TLS audit
      lines present with timing (confirms `run_tls_checks` wired into
      `run_checks`).

What to look for:
- Every check should also appear, with timing, in the default
  `uv run validate-private` run. If the TLS lines are missing there,
  `run_tls_checks` is not wired into `run_checks`.
- A check that PASSes with an empty or "skipped" detail on a stack that has
  `AdvertisedDNS` set is a vacuous pass. The skip branch should only fire when
  `config.advertised_dns` is empty, which never happens for Private.
- `Served cert identity` is the subtle one: it must fail on a mismatch, not
  merely confirm a cert exists. Verify it in Phase 3.

### Phase 1 findings: two real check bugs (NOT stack defects)

The Phase 1 command `./deploy.py --region us-east-1` defaults
`CreatePrivateDns=false`. `resolve_tls_plan` then sets a *synthetic*
`AdvertisedDNS=neo4j-<stack>.neo4j.local` used only for the cert SAN, the
Neo4j `server.default_advertised_address`, and Jetty `sniHostCheck`. The
template creates the Route53 hosted zone and alias record (`networking-private.yaml`
`Neo4jPrivateDnsHostedZone` / `Neo4jAdvertisedDnsRecord`) **only** under
condition `CreatePrivateDns == 'true'`. Confirmed by
`describe-stack-resources` (no Route53 resources) and `route53
list-hosted-zones` (no `neo4j.local` zone). In this default mode in-VPC
clients connect via `neo4j+ssc://<nlb-aws-dns>` with cert verification
disabled, so the synthetic name is never resolved by anything. This is the
documented default (sample-private-app does exactly this).

Bastion reproduction (SSM `AWS-RunShellScript` on `i-028c97ba8d3891f91`):

- `getent hosts <nlb-aws-dns>` -> three VPC IPs (`10.0.x`)
- `getent hosts neo4j-test-ee-1778972234.neo4j.local` -> no address
- `curl -sk https://<nlb-aws-dns>:7473/` -> **400**
- `curl -sk --resolve neo4j-test-ee-1778972234.neo4j.local:7473:<nlb-ip>
  https://neo4j-test-ee-1778972234.neo4j.local:7473/` -> **200**

**Bug 1, `HTTPS reachable on 7473`** (`_probe_tls_dataplane` in
`checks.py`): it curls `https://<nlb-aws-dns>:7473/` and expects 200. Jetty
`sniHostCheck` (set by `templates/src/partials/configure-tls.sh`) returns
400 for any SNI/Host that is not the cert SAN. On a healthy default Private
stack 200 is only reachable when the request carries SNI/Host =
`AdvertisedDNS`. The check must resolve an NLB IP and curl with
`--resolve <advertised_dns>:7473:<nlb-ip> https://<advertised_dns>:7473/`,
not the raw NLB AWS hostname.

**Bug 2, `AdvertisedDNS resolves in-VPC`** (same helper): it hard-FAILs
whenever `CreatePrivateDns` is false, which is the default and the most
common Private deploy. The check assumes the name is always an in-VPC
record. It should assert resolution + alias-to-NLB only when the stack
actually owns the private DNS (`CreatePrivateDns=true` / a hosted zone is
wired), and otherwise record INFO/PASS-skip explaining the synthetic-SAN
default. The plan's own Phase 4 wording already scopes this to "when the
stack owns the private DNS"; the check ignores that conditionality.

Both are vacuous-FAIL bugs: the checks cannot pass on a healthy default
Private stack, which is exactly the failure mode this plan exists to catch,
in the opposite direction from a vacuous PASS. **No code changed yet:
fix approach is being discussed with the user (standing instruction: discuss
bug fixes before implementing; do not paper over).**

---

## Phase 2: sample-private-app conformance probe, positive path

```bash
cd neo4j-ee/sample-private-app
uv run deploy-sample-private-app.py
```

- [ ] Deploy prints `Running in-VPC TLS conformance probe...`
- [ ] Each hard check prints `[PASS]`: `plaintext_bolt_refused`,
      `https_7473_ok`, `plaintext_http_7474_refused`, `cert_identity`
- [ ] `[INFO] strict_tls:` prints; for the default self-signed ACM cert it
      reports not CA-trusted, and that is expected, not a failure
- [ ] `TLS conformance: PASS` prints and the deploy continues to completion
- [ ] `./invoke.sh` returns a body with NO `tls_conformance` key (the demo path
      must not run the probe)
- [ ] Invoking with `{"tls_probe": true}` does include `tls_conformance`

What to look for:
- The probe must run only on the gated path. Confirm `./invoke.sh` output is
  unchanged from before this branch except for `tls_enabled`/`bolt_scheme`.
  If `tls_conformance` appears on the plain demo call, the event gate
  (`event.get("tls_probe") is True`) is not effective and the hot path took
  the 8s plaintext-probe penalty.
- Measure demo latency: `time ./invoke.sh` on a warm Lambda should not carry an
  extra multi-second TLS handshake/timeout cost.

---

## Phase 3: Negative tests (the part that proves the checks work)

A green run on a healthy stack does not prove the checks detect failure. Induce
each failure once and confirm the matching check flips to FAIL with a useful
detail. These are deliberate, reversible perturbations on a throwaway stack.
Revert each before inducing the next.

### 3a. Served-cert identity mismatch

On one cluster instance, regenerate the HTTPS cert with a wrong CN, then
restart Neo4j:

```bash
# via uv run admin-shell host, or SSM session to the instance
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /var/lib/neo4j/certificates/https/private.key \
  -out /var/lib/neo4j/certificates/https/public.crt \
  -days 1 -subj "/CN=wrong.example" -addext "subjectAltName=DNS:wrong.example"
chown -R neo4j:neo4j /var/lib/neo4j/certificates/https
systemctl restart neo4j
```

- [ ] `Served cert identity matches AdvertisedDNS` flips to FAIL
- [ ] Detail names the served subject/SAN and `AdvertisedDNS`, not a generic error
- [ ] `sample-private-app` probe `cert_identity` flips to FAIL and the deploy
      script exits non-zero

Then restore the original cert (or let ASG self-heal replace the node) and
confirm the check returns to PASS.

### 3b. Plaintext exposure

Temporarily flip the instance to plaintext to prove the negative checks bite:

```bash
# on one instance
sed -i 's/^server.bolt.tls_level=REQUIRED/server.bolt.tls_level=OPTIONAL/' /etc/neo4j/neo4j.conf
sed -i 's/^server.http.enabled=false/server.http.enabled=true/' /etc/neo4j/neo4j.conf
systemctl restart neo4j
```

- [ ] `TLS conf (<instance-id>)` for that node flips to FAIL, listing the
      offending keys with actual vs expected values
- [ ] The other nodes still PASS, proving the audit is per node

Revert the conf and restart.

### 3c. Control-plane drift

In the console or CLI, change the Browser listener `SslPolicy` away from the
PQ policy on the test stack's NLB.

- [ ] `NLB TLS listeners` flips to FAIL, detail names the wrong policy
- [ ] Reverting restores PASS

### 3d. Preflight gate

Hand-edit the local deploy outputs file under `neo4j-ee/.deploy/<stack>.txt`
and blank out `AdvertisedDNS`.

- [ ] `uv run preflight` reports the TLS-params check FAIL and exits non-zero
- [ ] Restoring the value restores PASS

What to look for across 3a-3d: the detail string must point at the actual
problem. A check that fails with only `ERROR: <stacktrace>` or an empty detail
is not actionable. Every FAIL should tell the operator what was expected and
what was observed.

---

## Phase 4: Topology coverage

The TLS checks must behave correctly across the supported shapes.

- [ ] ExistingVpc stack (`./deploy.py --mode ExistingVpc ...`): `--suite tls`
      passes, including `AdvertisedDNS resolves in-VPC` when the stack owns the
      private DNS
- [ ] Single-node Private stack (`--number-of-servers 1`): exactly one
      `TLS conf` line, and the Bolt checks still pass
- [x] Public without TLS (`./deploy.py --mode Public`): `validate-private`
      refuses this stack at config load, which is correct. The probe-skip
      branch is exercised only by unit reasoning, not this CLI
      **VERIFIED 2026-05-16** against the existing Public stack
      `test-ee-1778912278`: `uv run validate-private --stack
      test-ee-1778912278 --suite tls` exits **1** with
      `ERROR: Required field(s) missing from test-ee-1778912278.txt:
      Neo4jOperatorBastionId`. The refusal happens at config load (a Public
      stack has no SSM bastion), is non-vacuous, and names the missing field.
      The refusal is on the absent bastion rather than a TLS-specific message,
      which is the correct and earliest gate for this CLI.
- [x] Release gate: `uv run validate-private --suite release
      --expected-cypher-default <v>` includes the TLS lines and still gates on
      version drift
      **VERIFIED 2026-05-17** against the recovered `test-ee-1778986767`
      (post-3b, all 3 nodes back healthy, preflight 12/12, default suite
      22/22). `uv run validate-private --stack test-ee-1778986767 --suite
      release --expected-cypher-default CYPHER_25` exits 0, **All 28 tests
      PASSED** (149.6s). The full TLS enforcement audit appears in the
      release run with timing, including the kill-loop-fixed line
      `PASS: 7473 TCP, 7687 TCP`. Version drift is asserted, not merely
      recorded: `Neo4j Kernel 2026.04.0 (enterprise)`,
      `db.query.default_language=CYPHER_25; expected CYPHER_25`, and per-node
      `rpm=2026.04.0-1; java=openjdk 25.0.3; db.query.default_language=CYPHER_25`.
      Effective default confirmed independently via `SHOW SETTINGS` ->
      `CYPHER_25` before choosing the expected value.

---

## Sign-off checklist

- [ ] Phase 0 fully green
- [ ] Phase 1 all PASS, exit 0
- [ ] Phase 2 probe PASS on gated path, absent on demo path
- [ ] Every Phase 3 negative test observed flipping to FAIL and back to PASS
- [ ] Phase 4 topologies covered
- [ ] No vacuous PASS found: every check was seen to fail at least once
- [ ] Throwaway test stacks torn down: `./teardown.sh` then, if needed,
      `./teardown.sh --delete-volumes`

---

## Notes and known limitations

- The data-plane probes run from the operator bastion over SSM, the same
  transport `run_blocklist_check` uses. A bastion that is not SSM-online makes
  these checks FAIL with an SSM error, not a TLS verdict. Run `uv run preflight`
  first and treat its bastion check as the gate.
- `strict_tls_info` is informational by design. With the auto-imported
  self-signed ACM cert it will report not-trusted forever. Do not turn this
  into a hard failure; a real public cert is the only thing that flips it, and
  self-signed is a supported mode.
- `getent hosts` is used for the in-VPC resolution check because `dig` is not
  guaranteed on the bastion. If resolution fails for an externally managed DNS
  name on an ExistingVpc stack, confirm whether the stack actually owns the
  hosted zone before treating it as a regression.
- The sample-app probe opens a connection to a closed port on purpose. The 8s
  timeout is the worst case for `plaintext_bolt_refused`. This is acceptable
  only because the probe is gated off the demo path; if you ever see multi
  second latency on `./invoke.sh`, the gate has regressed.
