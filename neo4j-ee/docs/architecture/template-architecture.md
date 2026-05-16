# Template Architecture: AMI, Template, UserData, and Bootstrap

This is the finalized, hardened architecture for the Neo4j Enterprise Edition
CloudFormation templates and the durable contract for changing them. It records
the design rationale, what was fixed, the goals, and the non-functional
requirements with the tests that enforce them, so future changes are placed by
an explicit rule instead of re-opening a debate that has churned across many
iterations. When this document disagrees with the repository, prefer the code
as built and update this document.

---

## 1. Overview and Design Rationale

A Neo4j EE deployment is produced by four layers, each with a single owner:

- **AMI**: a hardened Amazon Linux 2023 base image with OS patches, base
  packages, the Neo4j yum repo and GPG key, the CloudFormation helpers, and SSH
  hardening. It contains no Neo4j configuration and no orchestration logic.
- **Template**: the rendered CloudFormation YAML. It carries the static Neo4j
  configuration and the orchestration body as `AWS::CloudFormation::Init`
  metadata on the single shared `Neo4jLaunchTemplate`.
- **UserData**: a thin wrapper. It resolves runtime values, runs `cfn-init`,
  invokes the bootstrap, and is the sole owner of `cfn-signal`.
- **Bootstrap**: the orchestration body delivered by cfn-init. It installs
  Neo4j and plugins, applies configuration, asserts the security invariant, and
  starts the service.

The instability that prompted this design was a recurring oscillation over
where Neo4j configuration should live. Two goals were in tension:

1. **Minimize AWS Marketplace resubmission churn.** Anything baked into the AMI
   requires an AMI rebuild, Marketplace submission, and instance replacement on
   running stacks to change. Logic that lives in the template is fixed by a
   template update with zero Marketplace churn.
2. **Make the security baseline un-droppable.** The
   `internal.dbms.cypher_ip_blocklist` key is a documented security invariant.
   It must be owned by one version-controlled artifact, guarded by tests, and
   impossible to silently drop.

The first design tried to satisfy goal 2 by moving configuration into the AMI,
which directly sabotages goal 1. It would have made the single most important
security key the single most expensive key in the system to ever change or
correct.

The resolved pattern satisfies both goals at once. Static configuration is
owned by a committed `templates/src/neo4j-base.conf`. `build.py` renders that
file verbatim into the template as cfn-init metadata. At boot the bootstrap
applies every key through the safe `set_neo4j_conf` primitive. Configuration is
one readable, version-controlled, test-guarded artifact, and every fix to it
remains a template update. Nothing config-related goes into the AMI.

---

## 2. What Was Fixed

Three concrete failure modes from earlier iterations are now closed:

- **`conf.d` does not exist.** No current Neo4j version has a `neo4j.conf.d/`
  drop-in mechanism. This was verified for the 5.26 LTS line and the 2025-2026
  calendar series. `neo4j.conf` is the single configuration source with no
  fragment merging, so fragments installed to a drop-in path would never be
  read. This rejection is version-independent.
- **Config in the AMI is incoherent with the churn goal.** Baking
  configuration maximizes the exact Marketplace resubmission churn the design
  exists to minimize, and it makes the security invariant the most expensive
  key to correct. Config in the AMI is only coherent if Neo4j itself is also
  baked in, which it deliberately is not.
- **Blind concatenation is unsafe.** The Neo4j package ships a `neo4j.conf`
  with keys already present, some uncommented. Neo4j does not reliably resolve
  duplicate keys. Configuration is applied only through `set_neo4j_conf`, which
  uncomments, replaces, or appends a key idempotently. Appending a duplicate of
  an already-set key is prohibited.

The deeper fix is structural: single sources of truth (one base-conf file, one
shared LaunchTemplate, explicit function contracts) plus contract tests that
fail when a change drifts back toward the rejected designs.

---

## 3. Key Goals

- **Zero Marketplace churn for the common break.** The most common version
  break is a renamed, removed, or default-changed setting. That class is fixed
  by editing `neo4j-base.conf` and rebuilding templates, with no AMI rebuild.
- **One version-controlled source of truth for static config.** Every fixed
  Neo4j key lives in `neo4j-base.conf`, never as an inline `set_neo4j_conf`
  call in a partial.
- **Defense in depth on the security invariant.** The blocklist is enforced at
  four layers: source file, build-time contract test, runtime fail-closed
  check, and post-deploy audit.
- **Marketplace-reviewable template shape.** A short UserData wrapper plus
  declarative cfn-init metadata is what Marketplace review expects and is far
  more reviewable than a large inline blob.
- **No cross-template or cross-node drift.** The orchestration body and
  base-conf are authored once on the single shared LaunchTemplate, never
  duplicated across the one-to-three ASGs.

---

## 4. The Placement Decision Rule

Any future configuration value or logic is placed by this rule. Apply the tests
in order. The first match wins.

1. **Does it depend on a stack input or an instance-runtime value** (load
   balancer DNS, ASG peers, instance RAM, a Secrets Manager ARN)? If yes, it is
   a **runtime overlay function** in a partial, taking that value as an
   explicit argument. Examples in `partials/configure-neo4j.sh`:
   `configure_network_advertised_addresses`, `configure_memory_recommendation`,
   `configure_cluster`, `configure_bolt_tls`, `configure_plugin_settings`.
2. **Is it a Neo4j configuration key with a fixed value on every deployment?**
   If yes, it is a **line in `templates/src/neo4j-base.conf`**, never an inline
   `set_neo4j_conf` call.
3. **Is it OS-level, immutable, and independent of Neo4j** (SSH hardening,
   pinned system user, base packages, OS patches, the cfn helpers)? If yes, it
   is **baked in the AMI** by `marketplace/create-ami.sh`.
4. **Is it CloudFormation signaling or metadata resolution that cannot be
   delegated** (`cfn-signal`, IMDSv2 fetch, tag lookups, `cfn-init`)? If yes,
   it **stays in UserData** (`templates/src/userdata.sh`).

**Configuration never reaches branch 3.** That is the rule the first design
violated. The rule is reusable: the next addition is placed by these four
branches, not by ad hoc judgement, so it does not re-open the debate.

---

## 5. Architecture Decisions

### AD-1: Deploy-time install, unpinned, with a release-gated verification

Neo4j Enterprise and its JRE dependency are installed at boot from
`yum.neo4j.com/stable/latest`. No Neo4j or Java version is pinned in the AMI or
templates, so the resolved Neo4j version and its Cypher default-language
behavior track whatever `stable/latest` serves at launch.

**Rationale.** Pinning forces a Marketplace resubmission for every release
customers should receive, and it shifts the entire Neo4j security-patch cadence
onto this project, gated by Marketplace review latency. Within a calendar
series, patch releases are rarely breaking. The render-from-committed-base
design makes the most common version break, a renamed or removed or
default-changed setting, fixable by editing `neo4j-base.conf` with no AMI
rebuild. The common case is cheap by design and the rare case is expensive,
not the reverse.

**This decision is sound only while the release-gated verification exists and
passes.** There is an exposure window between `stable/latest` rolling forward
and verification catching a break. During that window new launches and ASG
self-heal use the new version. The dangerous case is ASG self-heal: a broken
`stable/latest` turns instance replacement into an availability failure with no
automated recovery. The compensating control is a rigorous release-triggered
verification run, not version pinning. That window and that risk are the reason
verification is a required release gate, not an optional step.

**Failure playbook.**

- **Config-shaped break**, such as a renamed, removed, or default-changed
  setting: fix by editing `neo4j-base.conf` and rebuilding templates. No AMI
  rebuild. This is the common case.
- **Binary-shaped break**, such as an unmet Java requirement, a repo
  restructure, a GPG key rotation, or `aws-cfn-bootstrap` being dropped: no
  template fix exists. The only response is an emergency version pin or a
  base-image fix plus an AMI rebuild and resubmission. This is the rare case.

### AD-2: Runtime fail-closed on the security invariant, presence-only

After configuration is applied and before `cfn-signal`, the bootstrap runs
`assert_security_invariant`. It reads `internal.dbms.cypher_ip_blocklist` from
`neo4j.conf` and calls `fail()` if it is absent or empty. The non-zero exit
trips UserData's ERR trap, which signals failure. The instance never enters
service without the invariant.

**The check is deliberately scoped to presence and non-emptiness only. It must
not validate the CIDR list contents.** Exact-content correctness is asserted by
the build-time contract tests, where a failure is caught before Marketplace
submission rather than at a customer launch.

**Rationale.** The asset at risk is the customer's own AWS credentials. The
blocklist stops Cypher procedures such as `apoc.load.json` from reaching
`169.254.169.254` and private VPC ranges. For a Marketplace product, refusing
to serve an instance missing this guard is the security-correct default. On the
happy path the key is always set, so the check never fires. The only realistic
way it breaks a good deployment is a false positive from over-validation. A
check that asserts exact CIDR contents would fail good instances the first time
the list is legitimately tuned or Neo4j normalizes the value, breaking every
launch and every ASG self-heal with no template fix. Presence-only keeps the
false-positive surface minimal.

**Widening this runtime check into content validation is prohibited by this
decision.** Any change that grows the check re-opens this decision.

### AD-3: Bootstrap delivered through cfn-init metadata on the shared LaunchTemplate

The orchestration body (`templates/src/bootstrap/neo4j-bootstrap.sh` with
partials inlined) and `neo4j-base.conf` are delivered by
`AWS::CloudFormation::Init` metadata attached to the single shared
`Neo4jLaunchTemplate`. They are not baked in the AMI and not inlined in
UserData. `build.py` renders this metadata. UserData runs
`cfn-init --resource Neo4jLaunchTemplate`, exports resolved runtime values as
named environment variables, invokes the bootstrap, then signals
CloudFormation.

Key properties:

- **`cfn-signal` has exactly one owner: UserData.** A non-zero exit from
  cfn-init or the bootstrap trips the ERR trap and signals failure. Execution
  never reaches `cfn-signal --success true`. This preserves protection against
  the worst Marketplace outcome, a wedged stack that is never signaled. Do not
  split the signaling owner between UserData and the bootstrap.
- **The Secrets Manager password travels by exported environment variable,
  never on the argument vector.** argv is visible in the process list and
  cloud-init logs. The bootstrap takes no positional arguments and reads no
  ambient global; every required runtime variable is validated in its prologue
  and `fail()`s if unset.
- **Content is embedded as plain YAML literal blocks, not `Fn::Sub`.** The
  bootstrap uses bash `${...}` pervasively. `Fn::Sub` would require escaping
  every shell expansion and would break byte-determinism. Literal-block
  embedding keeps the rendered metadata byte-deterministic.
- **Metadata lives on the one shared LaunchTemplate**, authored once per
  rendered template, never triplicated across the one-to-three ASGs. This
  removes the cross-template and cross-node divergence class.
- **UserData has a hard 16 KB cap after base64.** Init metadata does not count
  against the cap. UserData stays a small wrapper with headroom.
- **No new IAM privilege.** The instance role already grants
  `cloudformation:DescribeStack*`, which covers cfn-init.

The base-conf staging path is `/opt/neo4j/conf/neo4j-base.conf`, not
`/var/lib/neo4j`. `/var/lib/neo4j` is owned by the `neo4j-enterprise` RPM and
cfn-init runs before the package is installed. `/opt/neo4j` is collision-free
against the RPM and is the shared home of the bootstrap, so base-conf and
bootstrap form one cleanly cfn-init-owned artifact set.

---

## 6. The AMI / Template / UserData / Bootstrap Split

| Layer | Owns | Changeable by | Examples |
|---|---|---|---|
| **AMI** (`marketplace/create-ami.sh`) | OS-level, immutable, Neo4j-independent concerns | AMI rebuild + Marketplace submission + instance replacement | OS patches; AWS CLI v2; `python3.11`, `jq`; `amazon-cloudwatch-agent`; `aws-cfn-bootstrap` (`cfn-init`, `cfn-signal`); Neo4j yum repo + GPG key; `neo4j` system user (uid/gid 500); SSH hardening; IMDSv2 enforcement |
| **Template** (rendered by `build.py`) | Static Neo4j config and orchestration body, as cfn-init metadata on `Neo4jLaunchTemplate` | Template update, zero Marketplace churn | `neo4j-base.conf` contents; the inlined bootstrap script |
| **UserData** (`templates/src/userdata.sh`) | CloudFormation signaling and metadata resolution that cannot be delegated | Template update | IMDSv2 token + instance-id/AZ fetch; stack-id and logical-id tag lookups; password fetch from Secrets Manager; `cfn-init`; export of runtime env vars; bootstrap invocation; `cfn-signal`; ERR trap |
| **Bootstrap** (`templates/src/bootstrap/neo4j-bootstrap.sh` + partials) | Boot-time install, configuration application, security assertion, service start | Template update | `install_neo4j_from_yum`, `install_apoc`, `install_plugin`; `apply_base_conf`; runtime overlay functions; `assert_security_invariant`; `start_neo4j` |

The AMI carries no Neo4j configuration key, no value, and no conf-mutating
logic. The same AMI is reused across all three topologies: Public, Private, and
Private Existing VPC.

---

## 7. The Security Invariant and Defense in Depth

`internal.dbms.cypher_ip_blocklist` is the single most protected key in the
system. Its value in `neo4j-base.conf` covers the IMDS credential range
(`169.254.169.0/24`), the RFC1918 VPC-internal ranges (`10.0.0.0/8`,
`172.16.0.0/12`, `192.168.0.0/16`), and the IPv6 unique-local and link-local
ranges. Removing it would let any Cypher user steal the instance IAM role
credentials and pivot into the VPC.

It is enforced at four independent layers:

1. **Source of truth.** It is a line in committed `templates/src/neo4j-base.conf`.
2. **Build-time contract.** `build.py` embeds the file verbatim. The
   `Neo4jBaseConfTests` and `RenderedTemplateContractTests` assert the exact
   content. A defective build fails before Marketplace submission.
3. **Runtime fail-closed.** `assert_security_invariant` aborts the boot before
   `cfn-signal` if the key is absent or empty (AD-2, presence-only).
4. **Post-deploy audit.** The G3 conf-key audit in `validate-private` asserts
   the key is present and non-empty on every node of a live stack.

The related access-control keys in `neo4j-base.conf`
(`dbms.security.procedures.unrestricted`,
`dbms.security.procedures.allowlist`, `dbms.security.http_auth_allowlist`) are
static keys and follow branch 2 of the Placement Decision Rule.

---

## 8. Prohibitions

Each item below is a rejected design. A change that reintroduces it is a
regression, not an improvement.

- **Do not put Neo4j configuration in the AMI.** It maximizes Marketplace
  churn and makes the security invariant the most expensive key to correct.
- **Do not use a `conf.d` drop-in mechanism.** It does not exist in any current
  Neo4j version. Fragments would never be read.
- **Do not blindly concatenate config files.** Neo4j does not resolve duplicate
  keys. Apply config only through `set_neo4j_conf`.
- **Do not pass the Secrets Manager password as a positional argument.** argv
  is visible in the process list and cloud-init logs.
- **Do not widen the runtime security check into content validation.** It would
  fail good instances the first time the list is legitimately tuned, with no
  template fix and full ASG-self-heal blast radius.
- **Do not split the `cfn-signal` owner between UserData and the bootstrap.**
  It produces double-signaled or never-signaled stacks.
- **Do not embed the bootstrap through `Fn::Sub`.** The bootstrap uses bash
  `${...}` pervasively; `Fn::Sub` breaks escaping and byte-determinism.
- **Do not replicate metadata across the ASGs.** It reintroduces the
  cross-template and cross-node drift the design exists to prevent.
- **Do not bake the bootstrap script into the AMI.** It makes every
  orchestration fix an AMI rebuild and Marketplace resubmission.
- **Do not add a static Neo4j key as an inline `set_neo4j_conf` call.** Fixed
  keys belong in `neo4j-base.conf` (Placement Decision Rule branch 2).

---

## 9. Non-Functional Requirements and Enforcing Tests

Tests are the executable specification. The design churned because the
rationale lived in people's heads and was re-litigated each time. A regression
toward a rejected design now fails a test rather than passing a review.

NFR numbers are stable identifiers, not a sequence. Some are cited directly in
code comments (`NFR-9` in `userdata.sh`, `NFR-6` in `build.py`), so the numbers
are kept fixed and gaps in the list below are intentional.

| NFR | Requirement | Enforced by |
|---|---|---|
| NFR-1 | No static or security key from `neo4j-base.conf` appears as an inline `set_neo4j_conf` call in any partial | Guard test that greps every `partials/*.sh` |
| NFR-2 | `neo4j-base.conf` content, including the blocklist, is exactly as specified | `Neo4jBaseConfTests` |
| NFR-3 | `marketplace/create-ami.sh` writes no Neo4j config key, value, or conf-mutating logic | AMI source assertion; no config in AMI |
| NFR-4 | Configuration is applied only through the idempotent `set_neo4j_conf` primitive, never blind append | `set_neo4j_conf` unit tests; NFR-1 guard |
| NFR-5 | Runtime values pass as named, validated, exported env vars; no ambient global; password never on argv | Bootstrap prologue validation; isolation tests |
| NFR-6 | `build.py --verify` passes: committed templates are byte-identical to a fresh assembly | `build.py --verify` in CI |
| NFR-9 | Boot fails closed before `cfn-signal` if the blocklist is absent or empty; the check stays presence-only | `assert_security_invariant` unit tests; AD-2 |
| NFR-10 | `cfn-init` and `cfn-signal` are present on the built image | `test-ami.sh` CHECK 11 (PATH resolution of both helpers) |
| NFR-11 | Rendered UserData of every template is well under the 16 KB post-base64 cap | Build-time size guard |

`RenderedTemplateContractTests` additionally assert the rendered cfn-init
metadata, the single-LaunchTemplate placement, and the embedded base-conf
content (AD-3, security invariant layer 2).
