# Public Template — Automated Test Plan

## Goal and Current Gap

`neo4j-public.template.yaml` creates an internet-facing NLB in public subnets — the topology intended for proof-of-concept and demo use. The current test documentation (`README.md:189-193`) covers only `test-observability.sh`. No automated connectivity, cluster-health, or security tests run against a public-mode deployment. The private-mode tooling (`validate-private/`) relies on an operator bastion and SSM tunnels that the public template does not provision.

`deploy.py:445` already prints `uv run test-neo4j --edition ee` as the post-deploy instruction, but `--edition ee` does not exist yet in the CLI.

The public template advantage over private: the NLB is internet-facing, so `test_neo4j` can connect directly over Bolt and HTTP from the developer machine — no SSM tunnels required.

---

## What Exists and Is Reusable As-Is

| Component | Location | Notes |
|---|---|---|
| Deploy | `neo4j-ee/deploy.py --mode Public` | Auto-detects public IP for `AllowedCIDR` |
| Teardown | `neo4j-ee/teardown.sh` | Ready |
| Observability | `neo4j-ee/test-observability.sh` | CloudWatch, logs, flow logs, alarm, CloudTrail |
| Connectivity checks | `test_neo4j/src/test_neo4j/neo4j_checks.py` | HTTP, auth, Bolt, APOC — fully generic |
| Movies dataset | `test_neo4j/src/test_neo4j/movies_dataset.py` | Bolt writes/reads — fully generic |
| Test reporter | `test_neo4j/src/test_neo4j/reporting.py` | No changes needed |
| Neo4j readiness wait | `test_neo4j/src/test_neo4j/wait.py` | No changes needed |
| Stack resource lookup | `test_neo4j/src/test_neo4j/aws_helpers.py:15-19` | `get_stack_resources()` is generic |
| External SG CIDR check | `test_neo4j/src/test_neo4j/infra_checks.py:181-232` | Reads `AllowedCIDR` CFN param — topology-agnostic |
| IMDSv2 check | `test_neo4j/src/test_neo4j/infra_checks.py:299-333` | Reads per-node launch template — topology-agnostic |
| JDWP absence check | `test_neo4j/src/test_neo4j/infra_checks.py:336-411` | SSM Run Command on instance — topology-agnostic |
| Port 5005 check | `test_neo4j/src/test_neo4j/infra_checks.py:235-259` | Internal SG check — topology-agnostic |

---

## What Needs to Be Built

Seven files need changes, one new file needs to be created. The sections below describe what changes, followed by the implementation order.

### A. `test_neo4j/src/test_neo4j/cli.py`

**Change 1 — `--edition` flag and conditional deploy dir.**
`cli.py:26` hardcodes `_DEPLOY_DIR = _REPO_ROOT / "neo4j-ce" / ".deploy"`. Add `--edition {ce,ee}` (default `ce`) and derive `_DEPLOY_DIR` from it: `neo4j-ce/.deploy/` or `neo4j-ee/.deploy/`.

**Change 2 — EE code path.**
The main function currently calls CE-specific functions: `run_infra_checks`, `run_resilience_tests`, `check_advertised_address`. For `--edition ee`, route to the EE equivalents built below.

### B. `test_neo4j/src/test_neo4j/config.py`

**Change — `edition` and `number_of_servers` fields.**
Add two fields to `StackConfig`:
- `edition: str` — value `"ce"` or `"ee"`. Populate from the `Edition` key that `deploy.py:425` writes to the output file. Used by `neo4j_deep_checks.py` and `cli.py` to dispatch CE vs EE checks.
- `number_of_servers: int` — populate from the `NumberOfServers` key in the output file (default `1`). Used by `cluster_checks.py` and `resilience.py` to skip Raft-specific checks on single-node stacks.

Both fields are added in the same step since they're both reads from the same output file and both needed by the same new code paths.

**Fail fast for private EE stacks.** `config.py` requires `Neo4jBrowserURL` and `Neo4jURI` (public template outputs them; private template does not). If those keys are absent, raise a clear error: "this test runner only supports public EE stacks (internet-facing NLB) — private EE stacks require SSM tunneling." Do not add a fallback to `Neo4jInternalDNS`.

Also: `InstallAPOC` is CE-only. `config.py:83` already uses `.get()` so it defaults to "no" for EE — no change needed there, but confirm the `install_apoc` field can remain and just default to `False` for EE stacks.

### C. `test_neo4j/src/test_neo4j/aws_helpers.py`

**Problem.** `get_asg_instance_id` (`aws_helpers.py:22-56`) and `wait_for_replacement_instance` (`aws_helpers.py:66-126`) both hardcode the logical resource ID `Neo4jAutoScalingGroup`. CE has one ASG with that name. EE has `Neo4jNode1ASG`, `Neo4jNode2ASG`, `Neo4jNode3ASG`.

**Change — add `asg_logical_id` parameter to both functions.** Default to `"Neo4jAutoScalingGroup"` so CE callers don't break. EE callers pass `"Neo4jNode1ASG"` (or whichever node). This is the foundational change that unblocks `volume_checks.py`, `infra_checks.py`, and `resilience.py`.

**Add — `get_all_ee_asg_instance_ids()`**, a new helper that iterates `Neo4jNode1ASG` through `Neo4jNode{N}ASG` (where N comes from `NumberOfServers` in the config or resource_map) and returns a list of `(asg_logical_id, instance_id)` pairs. Used by cluster-shape checks and EE volume checks.

### D. `test_neo4j/src/test_neo4j/neo4j_deep_checks.py`

**Change 1 — `check_server_status` edition string.**
`neo4j_deep_checks.py:22` hardcodes `expected = "community"`. Parameterize: pass `edition` from `StackConfig` and assert `"community"` for CE, `"enterprise"` for EE.

**Change 2 — skip `check_advertised_address` for EE.**
`check_advertised_address` (`neo4j_deep_checks.py:60-82`) validates that the advertised address matches the Elastic IP — CE-only concept. `run_deep_neo4j_checks` (`neo4j_deep_checks.py:138-144`) calls it unconditionally. Guard it behind `if config.edition == "ce":`.

### E. `test_neo4j/src/test_neo4j/infra_checks.py`

**Change — add `run_ee_infra_checks()`.**
The existing `run_infra_checks()` calls `check_elastic_ip()` and `check_asg_config()`, both CE-only. Add a new dispatch function for EE:

- **NLB scheme check (new)**: look up the `Neo4jNetworkLoadBalancer` logical resource in the stack, call `describe_load_balancers`, and assert `Scheme == "internet-facing"` for public mode.
- **Multi-ASG check (new)**: for each of `Neo4jNode1ASG` / `Neo4jNode2ASG` / `Neo4jNode3ASG` present in the resource map, verify `MinSize=MaxSize=DesiredCapacity=1` and `HealthCheckType=ELB`. Single-node stacks only have `Neo4jNode1ASG`.
- **Re-use unchanged**: `check_security_group_ports`, `check_external_sg_cidr`, `check_port_5005_absent`, `check_internal_sg_self_reference`, `check_imdsv2_enforced`, `check_jdwp_absent`.

**`--infra-security` flag**: keep it as an optional flag for EE, consistent with CE. The security checks (`check_imdsv2_enforced`, `check_jdwp_absent`) still require SSM Run Command permissions that not every run will have. Call them from `run_ee_infra_checks()` only when `--infra-security` is passed.

### F. `test_neo4j/src/test_neo4j/volume_checks.py`

**Problem.** `run_volume_checks` (`volume_checks.py:75-98`) calls `get_asg_instance_id` (CE ASG name) and looks up `Neo4jDataVolume` (CE logical resource ID). EE uses `Neo4jNode1DataVolume` / `Neo4jNode2DataVolume` / `Neo4jNode3DataVolume` and `Neo4jNode1ASG` etc.

**Change — add `run_ee_volume_checks()`.** Iterate over each node: get the instance ID from `Neo4jNode{N}ASG` (using the updated `aws_helpers` helper), look up `Neo4jNode{N}DataVolume` from the resource map, and call the existing `_check_volume()` helper unchanged.

### G. New `test_neo4j/src/test_neo4j/cluster_checks.py`

None of the existing checks verify the Raft cluster formed correctly. Create this module with three checks:

**`check_all_nodes_inservice(session, config, reporter, resource_map)`**
For each `Neo4jNode{N}ASG` in the resource map, assert exactly one instance is in `LifecycleState=InService`. Detects split-brain, failed launches, or nodes stuck in pending.

**`check_cluster_topology(config, reporter)`**
Run `SHOW SERVERS YIELD serverId, role, currentStatus` (Neo4j 5.x) via Bolt. Assert:
- Exactly `NumberOfServers` servers with `currentStatus=Enabled`.
- Exactly one `PRIMARY` role (leader) and two `SECONDARY` roles (followers) for a 3-node cluster, or one `PRIMARY` for a single-node cluster.
- Skip this check for single-node — no Raft election occurs.

**`check_routing_table(config, reporter, session, resource_map)`**
Call `CALL dbms.cluster.routing.getRoutingTable({database: 'neo4j'})` via Bolt. Assert:
- At least one writer endpoint present.
- At least two reader endpoints present.
- All endpoint IPs belong to EC2 instances in the cluster's ASGs: cross-reference with `get_all_ee_asg_instance_ids()` + `ec2.describe_instances` to get the private IP of each instance, then verify each routing table IP matches one of those private IPs. The template sets `server.routing.advertised_address = ${privateIP}:7688`, so entries will contain private IPs, not the NLB DNS name.
- Skip this check for single-node.

### H. `test_neo4j/src/test_neo4j/resilience.py`

**Problem.** The existing `run_resilience_tests` tests CE single-instance EBS persistence: write sentinel, terminate instance, wait for ASG replacement, verify data survived. This works correctly for 1-node EE.

For 3-node EE the correct test is: terminate one **follower**, verify the remaining two nodes elect/retain a leader, wait for the ASG to launch a replacement, verify the replacement joins as a follower, verify all data written before termination is still readable (the replacement reattaches its EBS volume and Raft sync catches up).

**Change — add `run_ee_cluster_resilience_tests()`.** Sequence:
1. Write sentinel data through the `neo4j://` URI (routes to leader).
2. Identify a follower EC2 instance to terminate:
   a. Call `get_all_ee_asg_instance_ids()` to get `[(asg_logical_id, instance_id), ...]`.
   b. Call `ec2.describe_instances` to get the private IP for each instance.
   c. Run `SHOW SERVERS YIELD address, role` via Bolt. The template sets `server.cluster.advertised_address = ${privateIP}:6000`, so addresses contain private IPs.
   d. Match private IPs between EC2 and Neo4j servers; pick any instance whose Neo4j role is not `PRIMARY`.
3. Terminate that follower's EC2 instance (via `aws_helpers.terminate_instance`).
4. Wait for its ASG (`Neo4jNode{N}ASG`) to launch a replacement (via the updated `aws_helpers.wait_for_replacement_instance` with the correct `asg_logical_id`).
5. Wait for `wait_for_neo4j` to pass on the Bolt URI (cluster is healthy).
6. Re-run `check_cluster_topology` — assert the cluster re-formed with a leader and two followers.
7. Verify sentinel data is still readable.

The existing `run_resilience_tests` for CE and 1-node EE remains unchanged.

---

## Phase Implementation Plan

Phases 1 and 2 are independent — run them in parallel. Phase 3 requires both to be complete.

### Phase 1 — Update `test_neo4j` ✅ COMPLETE

Make the nine code changes below in dependency order. Each step is independently testable; after Step 3 verify CE tests still pass before continuing.

### Phase 2 — Prepare and Deploy ✅ COMPLETE

Deployed `test-ee-1777182300` (3-node, Public mode, us-east-2, ami-00c5f98cd216e2f11).

**Template bug found and fixed during deploy:** `Neo4jExternalSecurityGroup` was attached to both the NLB and the instances, allowing only `AllowedCIDR` on 7474/7687. NLB health checks originate from the NLB's private VPC IPs, not `AllowedCIDR`, so all three targets failed health checks and the NLB could not route traffic. Fix follows the AWS-recommended pattern:
- `Neo4jNLBSecurityGroup` (new, on NLB): allows `AllowedCIDR` on 7474/7687. Filters external client traffic. No VPC CIDR hardcoded — works for any marketplace deployment.
- `Neo4jExternalSecurityGroup` (updated, on instances): sources from `Neo4jNLBSecurityGroup` via `SourceSecurityGroupId`. Allows both forwarded client traffic and NLB health checks. No CIDR dependency.

Files changed: `templates/src/security-groups-public.yaml`, `templates/src/networking-public.yaml`, `templates/neo4j-public.template.yaml`.

### Phase 3 — Validate ✅ COMPLETE — 29/29 functional + 9/9 observability

Requires Phase 1 and Phase 2 complete. Run both test suites against the deployed stack, then tear down.

```bash
# Functional checks (connectivity, cluster health, security, resilience)
cd test_neo4j
uv run test-neo4j --edition ee                     # most recent stack
uv run test-neo4j --edition ee --stack <name>      # specific stack

# Observability checks (CloudWatch, logs, flow logs, failed-auth alarm, CloudTrail)
cd ../neo4j-ee
./test-observability.sh                            # most recent stack
./test-observability.sh <stack-name>               # specific stack

# Tear down
./teardown.sh
```

> **`AllowedCIDR` constraint.** `deploy.py` sets `AllowedCIDR` to the deployer's public IP (`<ip>/32`). The Phase 3 test runner must execute from the same egress IP or the security group blocks Bolt and HTTP. For CI, pass `--allowed-cidr` to a static egress IP at deploy time.

### First run results (test-ee-1777182300, template with SG fix applied live) — 18/25 passed

| # | Test | Result | Root cause |
|---|------|--------|------------|
| 7 | Data directory | FAIL | Test expects `/data`; EE default is `/var/lib/neo4j/data`. Fix: update test assertion. |
| 12–14 | ASG HealthCheckType | FAIL | Template has `HealthCheckType: EC2`; should be `ELB` for NLB-backed ASGs. Fix: template. |
| 19 | Cluster topology (`SHOW SERVERS`) | FAIL | `role` column removed in Neo4j 2026.04; correct column is `currentPrimariesServingStatus` or equivalent. Fix: update Cypher in `cluster_checks.py`. |
| 20 | Routing table | FAIL | `dbms.cluster.routing.getRoutingTable` deprecated + no writer/reader endpoints returned (cluster Cypher issue). Fix: same Cypher update as #19. |
| 25 | Identify follower | FAIL | Same `role` Cypher syntax error as #19. Fix: same Cypher update. |

All connectivity, volume, NLB scheme, and sentinel data tests passed. The three root causes are: (1) one wrong test assertion, (2) one template ASG config, (3) one Cypher API change in Neo4j 2026.04.

**Second run (test-ee-1777184749) confirms SG fix is clean** — identical 7 failures, all in code/template, none in infrastructure. The NLB health checks now pass immediately on fresh deploy (no wait loop needed). Stack is live at `test-ee-1777184749-nlb-8b1881593b0d2c69.elb.us-east-2.amazonaws.com`.

### All fixes applied — final run `test-ee-1777190211`: 29/29 functional + 9/9 observability ✅ SHIP-READY

All three root causes fixed, plus two additional bugs exposed during the fix iterations:

| # | Fix | Location |
|---|-----|----------|
| 1 | Data directory: edition-aware assertion (`/var/lib/neo4j/data` for EE) | `test_neo4j/src/test_neo4j/neo4j_deep_checks.py` |
| 2 | ASG HealthCheckType: changed from `EC2` to `ELB`; added `HealthCheckGracePeriod: 600` | `templates/src/asg-public.yaml` + assembled template |
| 3 | Neo4j 2026.04 Cypher: `SHOW SERVERS YIELD name, state, health` + `SHOW DATABASES YIELD name, currentStatus, writer WHERE name = 'neo4j'` for leader detection; `dbms.routing.getRoutingTable` replaces deprecated `dbms.cluster.routing.getRoutingTable`; new response format `{servers: [{addresses, role}]}` | `test_neo4j/src/test_neo4j/cluster_checks.py` |
| 4 | UserData: `alternatives --install python3 → python3.11` ran before `cfn-signal`; cfn-signal shebang `#!/usr/bin/python3 -s` needs cfnbootstrap under python3.9. Fix: move alternatives to after cfn-signal | `templates/src/userdata-public.sh`, `userdata-private.sh`, `userdata-existing-vpc.sh` |
| 5 | Cluster topology timing: after follower replacement, HTTP up ≠ Raft quorum re-formed. Fix: poll `SHOW SERVERS` for up to 120s before running topology assertion | `test_neo4j/src/test_neo4j/resilience.py` |
| 6 | Follower identification: all bolt-advertised addresses point to NLB DNS (not private IPs), so IP-based role mapping fails. Fix: always terminate Node 2 (cluster survives any single node loss regardless of role) | `test_neo4j/src/test_neo4j/resilience.py` |

---

## Implementation Order (Phase 1 Detail)

Changes have hard dependencies: the right order prevents re-work.

```
Step 1  config.py              ✅ add `edition` and `number_of_servers` fields (read from output file); fail fast if Neo4jBrowserURL absent
Step 2  cli.py (--edition)     ✅ add flag + conditional deploy dir; EE code path left as TODO
Step 3  aws_helpers.py         ✅ add asg_logical_id param + get_all_ee_asg_instance_ids()
Step 4  neo4j_deep_checks.py   ✅ edition-aware server status; skip advertised address for EE
Step 5  volume_checks.py       ✅ add run_ee_volume_checks() using updated aws_helpers
Step 6  infra_checks.py        ✅ add run_ee_infra_checks() using updated aws_helpers
Step 7  cluster_checks.py      ✅ new module; depends on Bolt working (steps 1-4) + aws_helpers (step 3)
Step 8  resilience.py          ✅ add run_ee_cluster_resilience_tests() using cluster_checks + aws_helpers
Step 9  cli.py (EE path)       ✅ wire ee branch: call steps 4-8 in the right order
```

**Why this order:**

- Step 1 before Step 2: `cli.py` needs `config.edition` to dispatch CE vs EE branches; `cluster_checks` and `resilience` need `config.number_of_servers` to skip single-node paths.
- Step 2 before Steps 4-9: can't test any EE code path until the `--edition ee` flag routes to it.
- Step 3 before Steps 5-8: `volume_checks`, `infra_checks`, and `resilience` all call `get_asg_instance_id` and `wait_for_replacement_instance` — they need the `asg_logical_id` parameter before EE variants can be written.
- Steps 4-7 before Step 8: `resilience.py` calls `check_cluster_topology` from `cluster_checks` and reads the deep checks module.
- Step 9 last: the `cli.py` EE wiring is the integration point; all the components it calls must exist first.

Each step is independently testable. After Step 3, verify CE tests still pass. After each subsequent step, the EE path gains one more check.

---

For single-node deployments, `cluster_checks` and `run_ee_cluster_resilience_tests` are skipped automatically — detected from `NumberOfServers` in the deploy output file.
