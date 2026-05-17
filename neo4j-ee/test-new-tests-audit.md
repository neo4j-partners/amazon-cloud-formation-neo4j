# Audit log: executing test-new-tests.md

Detailed, append-only record of every test action: command, timestamp,
exit code, key output, verdict. Account 159878781974, region us-east-1.
Newest entries at the bottom of each phase.

---

## Phase 0 — Static checks (2026-05-16)

| Check | Command | Exit | Result |
|---|---|---|---|
| Unit suite | `python -m unittest discover -s tests` | 0 | `Ran 94 tests OK` |
| Build verify | `python build.py --verify` | 0 | all 3 templates up to date |
| cfn-lint EE x3 | `cfn-lint templates/neo4j-*.template.yaml` | 0 | clean |
| cfn-lint sample app | `cfn-lint sample-private-app/...yaml` | 0 | clean |
| py_compile | 6 changed files | 0 | OK |
| Imports | `import validate_private.{checks,cli,config}` | 0 | imports OK |
| StackConfig fields | dataclass field check | 0 | advertised_dns/certificate_arn True |
| `--help` lists tls | `validate-private --help` | 0 | `--suite {release,tls,...}` |

Verdict: **Phase 0 PASS, 8/8.** Only noise: unrelated samtranslator
Pydantic-V1-on-Py3.14 UserWarning from cfn-lint (does not affect exit 0).

---

## Phase 1 — Live positive path

Stack deployed: `test-ee-1778972234` (Private, 3-node, t3.medium,
self-signed auto-imported ACM cert, `AdvertisedDNS=neo4j-test-ee-1778972234.neo4j.local`,
bastion `i-028c97ba8d3891f91`). Deploy exit 0.

### Run 1 (pre-fix) — found 2 check bugs

`uv run validate-private --stack test-ee-1778972234 --suite tls` -> **exit 1**,
2 of 10 failed:

- `HTTPS reachable on 7473`: `GET https://<nlb-aws-dns>:7473/ -> 400`
- `AdvertisedDNS resolves in-VPC`: `did not resolve from bastion: no address`

`uv run preflight test-ee-1778972234` -> **exit 0**, `12 passed, 0 failed`,
+1 `[INFO]`. `TLS params set: CertificateArn, AdvertisedDNS` PASS.

Root cause (bastion SSM reproduction, `i-028c97ba8d3891f91`):

```
getent hosts <nlb-aws-dns>                       -> 10.0.12.206 / 10.0.10.39 / 10.0.11.228
getent hosts neo4j-test-...neo4j.local           -> GETENT_ADV_FAIL (no record)
curl -sk https://<nlb-aws-dns>:7473/             -> 400  (Jetty sniHostCheck)
curl -sk --resolve <adv>:7473:<ip> https://<adv> -> 200
```

`describe-stack-resources` shows zero Route53 resources;
`route53 list-hosted-zones` shows no `neo4j.local` zone. The default
`./deploy.py` path sets `CreatePrivateDns=false`, so AdvertisedDNS is a
synthetic cert SAN with no in-VPC record by design. Both failures are
check-code bugs, not stack defects. Documented in test-new-tests.md
"Phase 1 findings".

### Fixes applied (user-approved)

- Bug 1 (`checks.py` `_probe_tls_dataplane`): HTTPS 7473 probe now resolves
  an NLB IP on the bastion and curls `--resolve <adv>:7473:$IP
  https://<adv>:7473/`, forcing SNI=AdvertisedDNS (matches the adjacent
  cert-identity probe's `-servername`).
- Bug 2 (`config.py` + `checks.py`): added `StackConfig.create_private_dns`,
  derived from presence of the `Neo4jPrivateDnsHostedZoneId` deploy-outputs
  field (emitted only under the `CreatePrivateDns` template condition; no
  new AWS call). The resolve check now skip-passes with a stated reason when
  the stack does not own private DNS, and when it does, asserts the name
  resolves to one of the NLB's IPs (strengthened from "resolves to
  anything").

Regression after fix: `py_compile` OK, imports OK, `create_private_dns`
field present, `python -m unittest discover -s tests` -> `Ran 94 tests OK`.

### Run 2 (post-fix)

`uv run validate-private --stack test-ee-1778972234 --suite tls` -> **exit 0**,
**All 10 tests PASSED** (44.2s):

```
PASS 7473/7687 TLS with ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09
PASS 7473 HTTPS L7, 7687 TCP
PASS GET https://neo4j-test-ee-1778972234.neo4j.local:7473/ (SNI ...) -> 200
PASS no plaintext HTTP listener on 7474
PASS TLS handshake on 7687 returned a server certificate
PASS cert subject/SAN contains neo4j-test-ee-1778972234.neo4j.local
PASS <adv> is a synthetic cert SAN (CreatePrivateDns not set); ... no in-VPC record expected
PASS TLS conf enforced (bolt REQUIRED, https on, http off)  x3 (one per node)
```

### Run 3 (default suite, wiring check)

`uv run validate-private --stack test-ee-1778972234` -> **exit 0**,
**All 22 tests PASSED** (118.4s). The `=== TLS enforcement audit ===` block
and all 10 TLS lines appear with per-check timing inside the default run,
confirming `run_tls_checks` is wired into `run_checks` (Phase 1
"what to look for" item).

Verdict: **Phase 1 COMPLETE.** preflight 12+1, `--suite tls` 10/10 exit 0,
default 22/22 exit 0. Two pre-existing check bugs found and fixed; no stack
defect. Nothing else outstanding for Phase 1.

---

## Phase 2 — sample-private-app conformance probe

### Deploy attempt 1 (2026-05-16) — gate correctly FAILED, surfaced a product defect

`uv run deploy-sample-private-app.py test-ee-1778972234` -> stack deployed,
then `Running in-VPC TLS conformance probe...` ->
`ERROR: Lambda returned status 500: {"error": "ServiceUnavailable",
"message": "Unable to retrieve routing information"}` -> **deploy exit 1**.

Triage:
- `./invoke.sh` (plain demo path, no probe) -> identical HTTP 500
  `ServiceUnavailable / Unable to retrieve routing information`. So this is
  NOT a probe bug and NOT caused by the Phase-1 validate-private fixes.
- Lambda CloudWatch traceback: fails in
  `neo4j/_sync/io/_pool.py update_routing_table` ->
  `ServiceUnavailable("Unable to retrieve routing information")`, ~15s
  (connection timeout) per invocation.
- `configure-tls.sh` lines 51-52 set
  `server.default_advertised_address=${advertisedDNS}` and
  `server.bolt.advertised_address=${advertisedDNS}:7687`.
- Sanctioned `uv run run-cypher test-ee-1778972234 "SHOW SERVERS ..."` ->
  every server `address = neo4j-test-ee-1778972234.neo4j.local:7687`.
- Sanctioned `uv run run-cypher ... "CALL dbms.routing.getRoutingTable({},
  'neo4j')"` -> ALL ROUTE/READ/WRITE addresses =
  `neo4j-test-ee-1778972234.neo4j.local:7687`.
- That name has no DNS record anywhere (Phase 1: no Route53 zone/record;
  `getent` on the bastion fails to resolve it).

**Finding (PRODUCT DEFECT, default Private TLS mode):** with the default
`./deploy.py` path (`CreatePrivateDns=false`), the 3-node cluster advertises
its entire routing table by the synthetic, unresolvable AdvertisedDNS. Any
routed Bolt client (`neo4j://` / `neo4j+ssc://`) — the documented and
sample-app connection mode for 3-node — cannot resolve the routing table and
fails with `ServiceUnavailable`. The sample-private-app deploy-time TLS gate
behaved correctly: it detected the broken posture and failed the deploy
non-zero rather than letting it pass silently. validate-private's bastion
tooling tolerates it only because the Neo4j driver can fall back to the
resolvable NLB seed for routed refresh from the bastion; that tolerance is
client- and environment-specific and is why Phase 1 passed. It is not a
property to rely on, and the Lambda (a normal routed client) does not get
that fallback far enough to run queries.

Not introduced by the Phase-1 fixes. Introduced by the TLS branch's
`configure-tls.sh`: the no-TLS path (lines 11-12) advertises the resolvable
`loadBalancerDNSName`; the TLS path (lines 51-52) advertises AdvertisedDNS,
which is only resolvable when the stack also owns a Route 53 record for it
(`--create-private-dns` / a real external DNS name). Fix approach pending
user decision (touches the 4-layer-contract file
`templates/src/partials/configure-tls.sh` and/or `deploy.py` defaults
and/or documentation of a required flag). No code changed.

### Fix applied (user-approved: narrowed fix + amend AD-4)

Three exact diffs applied 2026-05-16:

- `templates/src/partials/configure-tls.sh` TLS branch: `server.default_advertised_address`
  and `server.bolt.advertised_address` now use `${loadBalancerDNSName}` instead
  of `${advertisedDNS}` (7-line WHY comment added). `server.https.advertised_address`
  stays `${advertisedDNS}:7473` (Jetty sniHostCheck). Cert SAN/CN unchanged
  (`${advertisedDNS}`). No-TLS branch was already on loadBalancerDNSName.
- `tests/test_template_partials.py::test_configure_tls_generates_certs_and_sets_keys`:
  default/bolt advertised-address assertions changed to `lb.example.com`;
  https.advertised_address + openssl SAN assertions unchanged.
- `docs/architecture/template-architecture.md` AD-4: cert-SAN paragraph scoped
  to HTTPS-only sniHostCheck + `server.https.advertised_address`; new "Bolt
  advertises the NLB DNS, not AdvertisedDNS" paragraph added.

Regression after fix:

| Check | Command | Exit | Result |
|---|---|---|---|
| Build + verify | `python build.py && python build.py --verify` | 0 | 3 templates up to date |
| Unit suite | `python -m unittest discover -s tests` | 0 | `Ran 94 tests OK` |
| cfn-lint x3 EE + sample app | `cfn-lint templates/neo4j-*.yaml sample-private-app/*.yaml` | 0 | clean |

Conf change requires a fresh deploy, so `test-ee-1778972234` is being torn
down and redeployed; Phase 1 + Phase 2 will be re-verified on the new stack.

### Redeploy 1 (`test-ee-1778982059`) — surfaced a regression in the 2-key fix

`./deploy.py` first attempt failed instantly: AWS SSO token expired
(`TokenRetrievalError`), no stack created. User re-ran `aws sso login`;
`sts get-caller-identity` OK (acct 159878781974). Redeploy exit 0:
stack `test-ee-1778982059`, bastion `i-031ad001ac5e3dda8`,
AdvertisedDNS `neo4j-test-ee-1778982059.neo4j.local`.

Phase 1 re-run on `test-ee-1778982059`:

- `uv run preflight test-ee-1778982059` -> **12 passed, 0 failed** (+1 INFO).
- `uv run validate-private --stack test-ee-1778982059 --suite tls` ->
  **1 of 10 FAILED**: `HTTPS reachable on 7473: GET https://<adv>:7473/
  (SNI <adv>) -> 000`. Other 9 PASS (incl. Bolt handshake, cert SAN,
  synthetic-SAN skip-pass, conf-enforced x3).

Root cause (decisive, single-variable):

| Evidence | Result |
|---|---|
| `describe-target-health` https-tg (7473) | all 3 **unhealthy** `Target.FailedHealthChecks` |
| `describe-target-health` bolt-tg (7687) | all 3 **healthy** |
| node `ss -tlnp` | Neo4j listening on 7473 + 7687 |
| `SHOW SERVERS` | 3 Enabled/Available; all advertise NLB DNS:7687 |
| node `curl https://127.0.0.1:7473/` (no SNI, = NLB health probe) | **400 "Invalid SNI"** |
| node `curl --resolve <adv>:7473:127.0.0.1 https://<adv>:7473/` | **200** |
| NLB 7473 health check (`networking-private.yaml:451`) | HTTPS `GET /`, matcher `200` |

The NLB HTTPS health checker sends no `SNI=AdvertisedDNS`; Jetty's no-SNI
fallback host is `server.default_advertised_address`. The 2-key fix set that
to the NLB DNS (!= cert SAN), so Jetty answers the SNI-less health check with
`400 Invalid SNI` -> all 7473 targets unhealthy -> NLB drops them ->
validate-private probe (via NLB) gets `000`. The old stack
(`default_advertised_address`=AdvertisedDNS=cert SAN) had healthy 7473
targets and returned 200; the single conf delta is `default_advertised_address`.

### Fix refined (user-approved: revert default_advertised_address only)

`server.default_advertised_address` reverted to `${advertisedDNS}` (it is
Jetty's no-SNI fallback host and must equal the cert SAN for the SNI-less NLB
7473 health check). `server.bolt.advertised_address` stays
`${loadBalancerDNSName}:7687` (Bolt has no `sniHostCheck`; bolt-tg health is
plain TCP and was already healthy; this still fixes the Phase 2 routed-client
defect). Comments + `test_template_partials.py` (`default_advertised_address`
assertion reverted to `neo4j.example.com`, bolt stays `lb.example.com:7687`)
+ AD-4 doc narrowed to Bolt-only.

Regression after refine:

| Check | Command | Exit | Result |
|---|---|---|---|
| Build + verify | `python build.py && python build.py --verify` | 0 | 3 templates up to date |
| Unit suite | `python -m unittest discover -s tests` | 0 | `Ran 94 tests OK` |
| cfn-lint x3 EE + sample app | `cfn-lint ...` | 0 | clean |

`test-ee-1778982059` being torn down + redeployed to re-verify Phase 1
(expect 7473 healthy, 10/10) and Phase 2 (expect routed probe PASS).

### CORRECTION — the `000` was a post-deploy readiness flake, NOT a config bug

Redeploy 2 (`test-ee-1778984306`, bastion `i-0e4ef9cadbcec3977`) with the
refined fix. Phase 1 first pass right after CREATE_COMPLETE:
`uv run validate-private --suite tls` -> **1 of 10 FAILED**, same
`HTTPS reachable on 7473 -> 000`. So reverting `default_advertised_address`
did **not** change the symptom — the root-cause claim two sections above is
**wrong** and is retained only as a corrected record.

Ground-truth diagnosis from the bastion (no redeploy):

| Probe (from bastion) | Result |
|---|---|
| EXACT validate-private probe, `--resolve <adv>:7473:<firstNLBIP>` | **HTTP 200** |
| same probe against **all 3** NLB IPs | **200, 200, 200** |
| direct to node IP:7473 | 000 (bastion SG has no direct node path; normal) |
| `describe-target-health` https-tg | all 3 `unhealthy` (NLB sends no SNI -> Jetty `400 Invalid SNI`) |

The HTTPS 7473 data plane is fully working: NLB **fail-open** (when all
targets are unhealthy NLB routes to all of them) plus `SNI=AdvertisedDNS`
from the probe -> Jetty `200`. The targets read "unhealthy" because the NLB
HTTPS health check connects without SNI and Jetty answers `400`; this is a
**pre-existing condition true on the old stack too** (its original Phase-1
Run-1 hit the NLB and got `400`, i.e. it was forwarding via fail-open from
the start), not introduced by any fix here. The `000` was simply HTTPS not
yet serving through the NLB in the first minutes after CREATE_COMPLETE.

Confirmation (same stack, **no redeploy**, re-run minutes later):

| Run | Command | Result |
|---|---|---|
| preflight | `uv run preflight test-ee-1778984306` | 12 passed, 0 failed |
| tls suite | `uv run validate-private --stack test-ee-1778984306 --suite tls` | **All 10 PASSED** (43.8s) |
| default | `uv run validate-private --stack test-ee-1778984306` | **All 22 PASSED** (119.1s) |

Verdict: **Phase 1 COMPLETE on the refined stack.** The refined fix
(`default_advertised_address`=`${advertisedDNS}`, only
`bolt.advertised_address`=`${loadBalancerDNSName}:7687`) is correct on its
own architectural merit (Bolt-only routed-client fix; HTTPS/cert untouched)
even though it was not what cleared the `000` symptom.

Open observation for "what else needs fixed" (NOT fixed, needs discussion):
the NLB HTTPS 7473 health check never passes (no SNI -> Jetty `400`), so the
7473 target group runs permanently on NLB fail-open with no real health
gating. Pre-existing, not in scope of this change.

### Lessons learned (running)

1. **"Unhealthy NLB targets" != broken data plane.** AWS NLB fail-open
   routes to all targets when every target is unhealthy. The HTTPS 7473
   target group has been on fail-open since the original stack because the
   NLB HTTPS health check connects without SNI and Jetty answers
   `400 Invalid SNI`. Always test the actual data path before concluding a
   defect from `describe-target-health`.
2. **Don't trust the first post-CREATE_COMPLETE probe.** HTTPS through the
   NLB took a few minutes past stack completion to serve; the first
   `--suite tls` run hit `000`, an unchanged re-run minutes later hit `200`.
   A single red probe immediately after deploy is not a defect signal.
3. **A wrong root-cause is expensive.** The `default_advertised_address`
   "single-variable" theory looked airtight but was disproven by reverting
   it and seeing the identical `000`. The deciding move was the cheap
   bastion ground-truth probe (all 3 NLB IPs -> 200), not more theory.
   Reproduce on the data path early.
4. **`server.default_advertised_address` must equal the cert SAN
   (`AdvertisedDNS`).** Independent of the flake, this is the correct
   architecture: it is Jetty's no-SNI fallback host. Only
   `server.bolt.advertised_address` may diverge to the NLB DNS because
   Bolt has no `sniHostCheck`.
5. **Scope a fix to the actual failing surface.** The Phase 2 routed-client
   defect lives only in the Bolt routing table, so only
   `server.bolt.advertised_address` needed changing. The first (2-key) fix
   over-reached into HTTPS-relevant config for no benefit.

## CRITICAL FINDING (Phase 3) — supersedes the "harmless fail-open" notes above

The earlier characterization (NLB 7473 health "pre-existing, harmless,
fail-open keeps the data plane working") is **WRONG and is corrected here**.

Evidence (`test-ee-1778984306`, during Phase 3, >20 min after deploy):

- All 3 Neo4j node ASGs: `HealthCheckType=ELB`, grace `1200s`.
- `describe-scaling-activities`: *"an instance was taken out of service in
  response to an **ELB system health check failure**"* — the 3 original
  nodes (launched 02:21:51) were terminated and replaced at 02:43–02:44.
- Only failing target group = `https-tg` (7473). The NLB HTTPS health check
  connects with no SNI; Jetty `sniHostCheck` answers `400 Invalid SNI`;
  target is permanently ELB-unhealthy.

**Defect:** in the default Private TLS deployment the 7473 ELB health check
never passes, and because the node ASGs use `HealthCheckType=ELB`, every
node is terminated ~20 min (grace) after launch and replaced — a permanent
self-heal kill loop. The cluster cannot survive past the grace window. NLB
fail-open hides it on the data plane only until the ASG kills the instance.
Phases 0–2 and the old stack's Phase 1 passed solely because all activity
finished inside the 1200s grace; the longer Phase 3 run crossed it. The
Phase 3 "conf missing x3 / `000`" failures were fresh mid-bootstrap
replacement nodes, not check bugs.

This revises lesson #1: NLB fail-open does NOT make unhealthy targets
harmless when the ASG health check type is ELB — it converts a failing L7
health check into continuous instance replacement.

Status: **STOPPED Phase 3** (stack is in a kill loop; further negative
tests on it are unreliable). Surfaced to user for a fix decision before any
change (touches `networking-private.yaml` health-check config and/or the
Jetty `sniHostCheck` posture and/or ASG `HealthCheckType` — a 4-layer /
template design decision, not a unilateral fix). 3d PASSED, 3c primary
check PASSED, before the loop was identified; 3a/3b not run.

### Fix applied (user-approved: Option 1 — 7473 health check → TCP)

User chose Option 1: change the `https-tg` (7473) target-group health
check from HTTPS to a TCP connect. Rationale: the NLB health checker opens
the TLS connection without an SNI server name; Jetty `sniHostCheck`
(cert SAN must be `AdvertisedDNS`) answers an HTTPS `GET /` probe
`400 Invalid SNI`, so the target can never go ELB-healthy. A TCP connect
is the strongest check NLB can run here without SNI; the L7 "Neo4j
actually serving" assurance is already covered by the `validate-private`
conf/TLS audit (G3/TLS suite).

Edits (source partials only; templates regenerated by `build.py`):

- `templates/src/networking-private.yaml` — `Neo4jBrowserTargetGroup`:
  `HealthCheckProtocol: TCP`, removed `HealthCheckPath` and `Matcher`
  (invalid for a TCP check), added the rationale comment.
- `templates/src/networking-existing-vpc.yaml` — identical change to its
  `Neo4jBrowserTargetGroup`.
- `templates/src/networking-public.yaml` — `Neo4jBrowserTargetGroup`
  conditionalized: `HealthCheckProtocol: !If [UsePublicTLS, TCP, HTTP]`,
  `HealthCheckPath`/`Matcher` `!If`-gated to `AWS::NoValue` under TLS.
  (Public defaults to plain TCP, so HTTP L7 health is kept when not TLS;
  only the new public-TLS branch needs the TCP behaviour.)
- `tests/test_template_partials.py` — private/existing_vpc Browser TG
  assertion updated to `HealthCheckProtocol == "TCP"`,
  `assertNotIn("HealthCheckPath")`, `assertNotIn("Matcher")` with the
  kill-loop rationale comment. `test_public_listeners_are_tls_conditional`
  needed no change (it asserts listener Protocol/Certificates/SslPolicy,
  not the target-group health check).

Verification (all green, from `neo4j-ee/`):

- `cd templates && python build.py && python build.py --verify` — three
  templates regenerated, all "up to date" (committed output byte-identical).
- `python -m unittest discover -s tests` — **94 tests OK**.
- `cfn-lint` on `neo4j-private`, `neo4j-public`,
  `neo4j-private-existing-vpc` — exit 0 (W1030 still scoped per-resource).
- `cfn-lint sample-private-app/sample-private-app.template.yaml` — exit 0.

### Option 1 fix VALIDATED on a live stack (`test-ee-1778986767`)

Validated against `test-ee-1778986767` (Private TLS, 3-node, created
2026-05-17 02:59Z with the fixed template; reads done with **direct
`aws`**, see the rtk-staleness lesson below):

1. **Template carries the fix**: `get-template` shows
   `Neo4jBrowserTargetGroup` with `Protocol: TLS` +
   `HealthCheckProtocol: TCP`, no `HealthCheckPath`, no `Matcher`.
2. **7473 targets are ELB-healthy**: all 3 instances in
   `test-ee-1778986767-https-tg` report `healthy` (Reason `None`).
   Pre-fix this group was permanently `unhealthy` (HTTPS probe → Jetty
   `400 Invalid SNI`). `bolt-tg` also 3/3 `healthy`.
3. **Kill loop gone**: each of the 3 node ASGs has exactly **one**
   scaling activity — the original launch at 03:02:47Z (desired 0→1).
   No "ELB system health check failure" terminations. Instances ~28+ min
   old, past the 1200 s grace, stable. (The old kill-loop stack
   `test-ee-1778984306` showed ELB-health terminations + replacements
   ~20 min after launch.)

The defect is fixed. `test-ee-1778986767` is a CREATE_COMPLETE stack
built with the fix; it will be used for the Phase 1/3 re-runs (per user
direction "validate fix on 1778986767 first" before any cleanup).

### Lesson: `rtk proxy` returns STALE CloudFormation reads

`rtk proxy aws cloudformation describe-stacks/list-stacks` returned
cached/stale results all session: it reported the kill-loop stack
`test-ee-1778984306` and the aborted `test-ee-1778986820/944` as
"does not exist", when direct `aws` shows them alive
(`CREATE_COMPLETE` / `CREATE_FAILED`). Acting on the stale reads led to
the false belief that the kill-loop stack was deleted; its 3 NAT
gateways + 3 EIPs (plus another stack's) silently consumed the account
EIP limit, which is the actual reason later deploys hit
`CREATE_FAILED` on `Neo4jNatEIP1/2/3` ("maximum number of addresses has
been reached"). **Why:** rtk caches/filters AWS responses; CFN/EC2
state changes faster than the cache. **How to apply:** for
CloudFormation/EC2/ELB/ASG state reads where a wrong "deleted/absent"
conclusion is costly, use direct `aws` (user-approved for this work),
not `rtk proxy`. The deploy failures were never a process kill and
never the Option 1 fix.

Next (per user direction): run Phase 1 (preflight + `--suite tls` +
default) and the remaining Phase 3 negatives (3a/3b) against
`test-ee-1778986767`; then propose an explicit account-cleanup plan
(orphaned stacks/VPCs/NAT-GWs/EIPs incl. the alive kill-loop stack,
2× CREATE_FAILED, 1× DELETE_FAILED, the unexpected
`test-ee-1778988352` CREATE_IN_PROGRESS) for approval before deleting
anything.

### Phase 1 re-run on `test-ee-1778986767` + 3rd check bug fixed

`.deploy/test-ee-1778986767.txt` had to be reconstructed from
CloudFormation outputs/params (deploy.py's nohup'd process was reaped
before it wrote the file; `load_config` requires the outputs file, and
the bastion-resolved password comes from Secrets Manager so it is not
needed in the file).

- `uv run preflight test-ee-1778986767` → **12 passed, 0 failed**.
- `uv run validate-private --stack test-ee-1778986767 --suite tls` →
  **1 of 10 FAILED**: `NLB target-group health checks: 7473 health
  check TCP != HTTPS`.

**3rd check bug (user-approved fix).**
`validate-private/src/validate_private/checks.py` (the `tg_check`
control-plane audit) asserted `browser.HealthCheckProtocol == "HTTPS"`
and labelled success `"7473 HTTPS L7, 7687 TCP"`. That is the **old
kill-loop expectation, inverted**: as written it PASSes a kill-loop
stack (7473=HTTPS) and FAILs a correctly-fixed one (7473=TCP). The
sibling data-plane check `HTTPS reachable on 7473` correctly still
PASSed (`GET https://…:7473/` with SNI → 200), so only the
control-plane health-check assertion was wrong.

Fix: assert 7473 `HealthCheckProtocol == "TCP"` (HTTPS now means the
kill-loop bug is present), success detail `"7473 TCP, 7687 TCP"`, plus a
rationale comment matching the three `networking-*.yaml` partials and the
`test_template_partials.py` contract test. After the fix:
`uv run validate-private --stack test-ee-1778986767 --suite tls` →
**all 10 PASSED** (preflight still 12/12). No validate-private unit
tests exist, so none needed updating; the build-time contract test was
already aligned to TCP.

## Phase 2 — re-test on refined stack `test-ee-1778984306`

Run from `sample-private-app/` (it is its own `uv` project;
`uv run deploy-sample-private-app.py <stack>` must be invoked from that dir,
not from `neo4j-ee/`).

Deploy: app CFN stack `neo4j-sample-private-app-test-ee-1778984306`
CREATE_COMPLETE, Function URL + artifacts written. Deploy-time gated probe
**FAILED**: `Lambda invocation failed: Sandbox.Timedout ... Task timed out
after 30.00 seconds`. Note this is a different failure than the original
defect (immediate HTTP 500 `ServiceUnavailable / Unable to retrieve routing
information`); a 30 s hang, not a fast fail.

Re-invoke minutes later (no redeploy):

| Path | Payload | Result |
|---|---|---|
| `./invoke.sh` (demo) | none | 200; `routing_table {writers:1, readers:2}`, all servers Enabled/Available |
| Function URL | `{"tls_probe": true}` | 200; `tls_enabled:true, bolt_scheme:neo4j+ssc, edition:enterprise`, populated `graph_sample`, `servers[]` |

**Phase 2 PRODUCT DEFECT is FIXED.** The routed `neo4j+ssc://` Lambda now
resolves the routing table (every ROUTE/READ/WRITE = the in-VPC-resolvable
NLB DNS:7687) and runs queries. Root fix: `server.bolt.advertised_address`
= `${loadBalancerDNSName}:7687` (Bolt-only; HTTPS/cert untouched).

The deploy-time `Sandbox.Timedout` was again a **post-deploy readiness
flake** (Lambda runs the gated probe seconds after CREATE_COMPLETE, before
Bolt-via-NLB + cold-start + TLS handshake fits in the 30 s Lambda limit);
the identical probe passes cleanly minutes later. Same lesson as Phase 1's
`000`.

Open observation for "what else needs fixed" (NOT fixed, needs discussion):
the sample-private-app deploy-time gate probes too eagerly — it should wait
for Bolt readiness (or retry within a longer budget) before the single 30 s
probe, otherwise a healthy stack fails the gate purely on post-deploy
timing. Pre-existing gate design, not in scope of the config fix.

Verdict: **Phase 2 COMPLETE.** Original product defect resolved by the
refined Bolt-only fix; gate-timing fragility logged as a separate
pre-existing item.
