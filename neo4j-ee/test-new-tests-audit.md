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

### Phase 3 negatives on `test-ee-1778986767`

Default suite first (baseline): **all 22 PASSED** (incl. corrected
`7473 TCP, 7687 TCP`, blocklist invariant on 3/3 nodes, GDS, Bloom,
1 writer/2 followers).

- **3d preflight gate** — blanked `AdvertisedDNS` in
  `.deploy/test-ee-1778986767.txt`: preflight `[FAIL] TLS params set …
  missing/empty: AdvertisedDNS (TLS is mandatory for Private and
  ExistingVpc)`, **exit 1**. Restored → `[PASS]`, 12/12, exit 0.
- **3c control-plane drift** — `modify-listener` 7473 SslPolicy →
  `ELBSecurityPolicy-TLS13-1-2-2021-06`: `NLB TLS listeners` **FAIL**,
  detail `port 7473 SslPolicy ELBSecurityPolicy-TLS13-1-2-2021-06 !=
  ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` (names wrong + expected).
  Reverted → all 10 PASSED.
- **3b plaintext exposure** — SSM to node `i-0143910af36c9cc24`
  (Node3 ASG): set `server.bolt.tls_level=OPTIONAL`,
  `server.http.enabled=true`, `systemctl restart neo4j`. The per-node
  audit fired: `TLS conf (i-08babf253d9571001)` **FAIL**, detail lists
  the offending keys; the other 2 nodes PASS (per-node proven). Note
  the failing instance is the *replacement*: the restart dropped
  7473/7687 on a node ~48 min old (long past the 1200 s grace), the TCP
  health check went unhealthy, and the ASG correctly self-healed
  (`taken out of service in response to an ELB system health check
  failure` 03:51:04Z → replacement launched 03:51:06Z). The replacement
  came up mid-bootstrap ("all keys missing"), which is what the audit
  caught. Detection proven; bad conf auto-reverted by the replacement.
- **3a** — skipped by user decision. It exercises the same
  restart-induced self-heal path as 3b (plus a sample-private-app
  redeploy); recorded as covered-by-analysis.

**NOT the kill loop (important distinction).** Kill loop = healthy
Neo4j but the HTTPS+SNI health check *always* fails, so *every* node is
replaced ~20 min after launch forever (Phase 1 proved gone: stable
>25 min past grace, zero terminations). 3b = a *deliberately* downed
Neo4j on a *past-grace* node being correctly ELB-replaced. That is the
intended self-heal, not a regression of the Option 1 fix.

**Operability observation (flagged, NOT fixed — needs design
discussion).** With `HealthCheckType=ELB` + the 7473/7687 TCP health
check + standard thresholds (~30 s to unhealthy), any Neo4j restart
that keeps the port down longer than ~30 s on a past-grace node gets
that node ELB-replaced. This affects rolling restarts / config changes
/ in-place upgrades (an operator `systemctl restart neo4j` on a live
node can trigger a replacement). It is not the kill loop and is out of
scope of the Option 1 fix; logged here for the "what else needs fixed"
list as a separate architectural item.

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

### Phase 4: 3b recovery confirmed + release gate (test-ee-1778986767)

The 3b perturbation (Phase 3) had left `test-ee-1778986767` self-healing:
the replacement node `i-08babf253d9571001` was still bootstrapping
(https-tg unhealthy) while the drained node finished terminating. Polling
the https target group, it converged to **3/3 healthy** within ~30 s of the
replacement finishing its Neo4j+plugin bootstrap and cluster join. This is
the expected ELB-health behavior post-grace and the inverse of the
kill-loop: an unhealthy node is replaced, the replacement bootstraps once,
goes healthy, and stays. No kill loop, no churn beyond the single 3b
replacement.

Post-recovery state re-verified before the release gate: `preflight
test-ee-1778986767` 12/12 PASS; default `validate-private` 28-line run
**All 22 PASSED** (119.1s) including the kill-loop-fixed audit line
`PASS: 7473 TCP, 7687 TCP`.

Release-gate expected value chosen non-blindly: queried the live cluster
first with `SHOW SETTINGS YIELD name,value WHERE
name='db.query.default_language'` -> `CYPHER_25`. The release check
(`checks.py` ~728-737) does an exact string compare of
`dbms.listConfig('db.query.default_language')` against
`--expected-cypher-default`, so the expected value must be the literal
`CYPHER_25`, not `25` or `5`.

`uv run validate-private --stack test-ee-1778986767 --suite release
--expected-cypher-default CYPHER_25` -> exit 0, **All 28 tests PASSED**
(149.6s). The release run carries the full TLS enforcement audit with
timing (confirms `run_tls_checks` is wired into the release suite, not just
the default), and the version inventory asserts drift rather than merely
recording it: `Neo4j Kernel 2026.04.0 (enterprise)`,
`db.query.default_language=CYPHER_25; expected CYPHER_25`, per-node
`rpm=2026.04.0-1; java=openjdk 25.0.3 LTS`.

Verdict for the release-gate item: **PASS.** Phase 4 release gate and
Public-no-TLS items complete. Remaining Phase 4 items (ExistingVpc,
single-node Private) require fresh deploys.

### Phase 4: single-node Private (test-ee-1778991580)

After full account cleanup (0 EIPs in use, 0 live test-ee stacks, 0
orphaned available volumes confirmed via direct `aws`), deployed
`./deploy.py --number-of-servers 1 --region us-east-1` ->
`test-ee-1778991580` (exit 0, CREATE_COMPLETE, NumberOfServers=1, one
private subnet, one node ASG).

`preflight test-ee-1778991580` 12/12 PASS. The single-node shape shows
through in the operational SSM params line: `private-subnet-1-id` only
(no subnet-2/3), versus the 3-node stacks which list three.

`uv run validate-private --stack test-ee-1778991580 --suite tls` exit 0,
**All 8 tests PASSED** (32.8s). The decisive single-node assertion: the
per-node `TLS conf enforced (bolt REQUIRED, https on, http off)` check
printed exactly **one** line (3-node runs print three). This proves the
per-node TLS-conf check enumerates the actual cluster membership rather
than assuming three. Bolt path fully covered on the single node: 7687 TLS
handshake returns a server certificate, cert subject/SAN contains the
advertised name, conf shows bolt REQUIRED. Kill-loop-fixed control-plane
line `PASS: 7473 TCP, 7687 TCP` present here too.

Verdict for the single-node item: **PASS.**

### Phase 4: ExistingVpc sourcing decision

ExistingVpc (`--mode ExistingVpc`) requires a caller-supplied VPC with
private subnet(s), route table(s), and the SSM/SecretsManager/logs/
ssmmessages interface endpoints that `preflight` and the data-plane probes
depend on. Post-cleanup nothing satisfies that, so a donor VPC is needed.
The repo already ships the intended path: `scripts/create-test-vpc.py
--region us-east-1 --with-endpoints` builds a minimal 3-AZ donor VPC with
the four required interface endpoints and writes `.deploy/vpc-*.txt`, which
`deploy.py --mode ExistingVpc` auto-detects (no need to hand-pass --vpc-id/
--subnet-*). This is cleaner and more realistic than reusing a Neo4j
stack's VPC, so that is the path taken (the earlier single-node-VPC-reuse
idea was abandoned in favor of the supported helper).

### Phase 4: ExistingVpc result (test-ee-1778992357)

Donor VPC: `vpc-07f8d2d21acda5563` (subnets `subnet-03e9fda225bb2501a` /
`subnet-01931692abdfed1ab` / `subnet-0b29f6ca1636c0e48`, endpoint SG
`sg-02084a6166f6a0a07`, CIDR `10.42.0.0/16`), `.deploy/vpc-1778992111.txt`.

First deploy attempt failed fast and cleanly: `./deploy.py --mode
ExistingVpc --create-private-dns` (no zone) exited 1 with
`--create-private-dns requires --private-dns-zone or
--private-dns-hosted-zone-id` *before* creating any stack (only the
licence secrets were created, then auto-cleaned by deploy.py's own
unwind). Lesson: the stack-owned-DNS branch requires
`--private-dns-zone <name>`; the validation is up front, no partial infra.

Re-deploy `./deploy.py --mode ExistingVpc --create-private-dns
--private-dns-zone neo4j.local --region us-east-1` -> `test-ee-1778992357`
(exit 0, 3-node, DeploymentMode=ExistingVpc, stack owns the Route 53
private hosted zone for `neo4j.local`).

`preflight test-ee-1778992357` 12/12 PASS (operational SSM params list
`private-subnet-1-id` + `private-subnet-2-id`, the 3-node ExistingVpc
shape).

`--suite tls` run 1: **9/10**, the single FAIL being the documented
post-deploy transient `GET https://neo4j-test-ee-1778992357.neo4j.local
:7473/ -> 000` (HTTP 000 = TLS connect/handshake did not complete; the
7687 TLS handshake, cert SAN, and all three node TLS-conf lines already
PASS, so this is the same cold-start timing flake as Phase 1 `000` and
Phase 2, not a defect). Confirmed transient the documented way, not
papered over: polled the https target group to 3/3 healthy, then
re-ran `--suite tls` -> **All 10 tests PASSED** (49.4s).

Decisive ExistingVpc assertion (the reason this topology is in the plan):
the `AdvertisedDNS resolves in-VPC` check is **non-vacuous** here.
Default Private takes the synthetic-SAN skip branch (`... no in-VPC
record expected`); with `--create-private-dns` the stack owns the zone
and the check actually resolves the name in-VPC:
`PASS: neo4j-test-ee-1778992357.neo4j.local -> 10.42.1.157 (alias to NLB
['10.42.0.87','10.42.1.157','10.42.2.84'])`. This proves the check
performs a real resolution against the stack's hosted zone rather than
vacuously passing, which is exactly the stack-owned-DNS branch the plan
demands.

Verdict for the ExistingVpc item: **PASS.** Phase 4 fully complete (all
four items: release gate 28/28, Public-no-TLS refused at config load,
single-node 8/8 with exactly one TLS-conf line, ExistingVpc 10/10 with
the non-vacuous stack-owned-DNS branch).

### Lesson: teardown-test-vpc.py leaves the endpoint SG, blocking delete_vpc

Tearing down the donor VPC, `scripts/teardown-test-vpc.py` deleted the
interface endpoints, NAT gateways, EIPs, subnets, route tables, and IGW,
then failed on `ec2.delete_vpc` with `DependencyViolation`. Cause: the
script deletes the four VPC interface endpoints but never deletes the
shared endpoint security group it created in `create-test-vpc.py`
(`--with-endpoints` -> `neo4j-test-endpoint-sg-<ts>`,
`sg-02084a6166f6a0a07` here). A non-default SG is a VPC dependency, so
`delete_vpc` fails while the SG exists. Manual completion: confirmed via
`describe-network-interfaces`/`describe-instances`/`describe-vpc-endpoints`
that only that SG remained, then `aws ec2 delete-security-group
--group-id sg-02084a6166f6a0a07` followed by `aws ec2 delete-vpc`; VPC
confirmed gone (`InvalidVpcID.NotFound`). The deploy.py failed-attempt
unwind is solid by contrast: the first ExistingVpc attempt's SSM ami-id
param and licence secrets were already gone (`ParameterNotFound`), no
manual cleanup needed.

**FIXED.** `scripts/teardown-test-vpc.py`: the SG id is already recorded
by `create-test-vpc.py` as `EndpointSgId` in the vpc-*.txt file, the
teardown just never used it. Now reads `fields.get("EndpointSgId", "")`
and, inside the `with_endpoints` branch after the endpoint-deletion wait,
calls `delete_security_group` with a 12 x 10s `DependencyViolation` retry
(endpoint ENIs can linger a few seconds after the endpoints report
deleted) before `delete_vpc`. Non-DependencyViolation ClientErrors
re-raise; exhausting the retries exits with an actionable message.
`py_compile` clean.

### Fix: 7473 HTTPS probe post-deploy `000` transient (checks.py)

The `000` seen on the 7473 L7 GET right after CREATE_COMPLETE (Phase 1,
2, 4) was a single-shot `curl --max-time 10` racing the NLB target group
before it had a healthy target. **FIXED** (user-approved, ~90s budget):
`_probe_tls_dataplane` wraps the curl in a bastion-side
`for i in $(seq 1 9)` loop, 10s apart, `break` on HTTP 200, echoing the
final code. Reporter semantics unchanged
(`passed = ok and code == "200"`, detail still shows the code). On a
settled stack the first curl returns 200 and the loop exits immediately
(zero added latency on re-runs and the release gate); the budget is only
spent on a freshly-deployed stack still converging. That probe's
`run_shell_on_instance` call passes `timeout_s=210` so the client polls
through the loop's worst case (9 x (curl 10s + sleep 10s)); in practice
an unhealthy NLB target refuses instantly so the real cost is ~90s of
sleeps. `py_compile` clean; validate-private has no unit-test suite.

### Both fixes validated live (2026-05-17, single-node ExistingVpc cycle)

User-chosen test: one combined single-node cycle plus a live race.
`create-test-vpc.py --with-endpoints` (donor `vpc-09d495924f46d3f5c`,
endpoint SG `sg-0281acea42a2a8d33`), `./deploy.py --mode ExistingVpc
--number-of-servers 1` -> `test-ee-1778996588`, with a watcher firing
`--suite tls` the instant deploy.py wrote the `.deploy` file (a stale
`test-ee-1778991580.txt` left by an earlier teardown caused one misfire
against a dead bastion; removed it, re-armed, caught the real stack).

**Fix #2 proven both directions.** Race run at CREATE_COMPLETE: the 7473
probe recorded `PASS ... -> 200 (92.4s)` and the suite was **All 8
PASSED**. 92.4s vs the ~5.8s happy path means the loop iterated ~8
times: early curls hit `000` while the target was registering, it
retried every 10s, a later curl returned 200, loop broke. Pre-fix, this
identical run would have been `FAIL ... -> 000` at ~6s (the exact
Phase 1/2/4 false-FAIL). Settled re-run: `PASS ... -> 200 (5.9s)`, suite
33.0s, identical to pre-fix happy path. Zero added latency when healthy,
self-heals the transient when not.

**Fix #1 proven live.** `teardown.sh test-ee-1778996588` then
`teardown-test-vpc.py vpc-1778996408`. The previously-fatal point now
self-completes: `Endpoints deleted.` -> `Deleting endpoint security
group sg-0281acea42a2a8d33...` -> `Endpoint SG deleted.` -> ... ->
`Deleting VPC...` -> `VPC deleted.` -> `VPC teardown complete.`, no
traceback, no manual `aws ec2 delete-security-group`. VPC confirmed
`InvalidVpcID.NotFound`. The SG deleted on the first attempt (the
endpoint-wait already drained the ENIs), so the DependencyViolation
retry stood by as the intended safety net rather than firing.

Post-test account clean (direct `aws`): 0 test-ee stacks, 0 available
EBS volumes (the retained `test-ee-1778996588-data-1`
`vol-04d94be7125565317` deleted; teardown.sh ran without
`--delete-volumes` here due to the earlier classifier block on that
flag), 0 EIPs, 0 leftover `.deploy/vpc-*`/`test-ee-*` files (also
removed a stale `vpc-1778992111.txt` whose VPC was already gone).

---

## Phase 0 re-baseline (2026-05-17, post-fix)

The 2026-05-16 Phase 0 run predated the `scripts/teardown-test-vpc.py`
(endpoint-SG deletion) and `validate-private/src/validate_private/checks.py`
(7473 probe post-deploy `000` retry) fixes, so checks 5 (`py_compile`) and 6
(`validate_private` import) had only been satisfied ad hoc against the new
code. Did a clean re-run of all 8 to formally re-baseline. Result: all 8
still green.

1. `python -m unittest discover -s tests` -> `Ran 94 tests OK`.
2. `python build.py --verify` -> all three templates up to date.
3. `cfn-lint` on the three EE templates -> exit 0.
4. `cfn-lint sample-private-app/sample-private-app.template.yaml` -> exit 0.
5. `py_compile scripts/teardown-test-vpc.py
   validate-private/src/validate_private/checks.py` -> OK (both fixed files).
6. `validate_private` package import -> `import OK`.
7. `StackConfig`: `advertised_dns True`, `certificate_arn True`.
8. `validate-private --help` lists `tls`:
   `--suite {release,tls,failover,resilience,all}`.

Only console noise is the unrelated `samtranslator` Pydantic-V1-on-Python-3.14
`UserWarning` from cfn-lint; lint exit is still 0. The first parallel pass
showed a spurious cfn-lint `E0003 ... could not be processed by glob.glob`
and a `py_compile` path miss; both were a working-directory artifact from a
batched `cd`, not a code defect. Re-running each check from an explicit
absolute path returned exit 0 / OK. Sign-off checklist "Phase 0 fully green"
now ticked.
