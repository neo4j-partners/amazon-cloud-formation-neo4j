# Plan: Automated Testing for neo4j-private-existing-vpc.template.yaml

## Goal

Run the full `validate-private` suite against the `ExistingVpc` template — deploy → preflight → validate → teardown — without any manual AWS console steps.

---

## Template isolation

The `ExistingVpc` template is assembled exclusively from `*-existing-vpc.yaml` source partials. The `Private` template uses a completely separate set of partials (`*-private.yaml`, `security-groups.yaml`, `networking-private.yaml`, etc.) and shares only `parameters-common.yaml`, `parameters-tls.yaml`, `iam.yaml`, and `ebs-volumes.yaml` — none of which are touched by this work. All changes below are isolated to `ExistingVpc` partials and `deploy.py`. The Private template is unaffected.

---

## What ExistingVpc adds vs Private

Structurally identical to `neo4j-private.template.yaml` (same bastion, same NLB, same cluster ASGs, same SSM contract) except:

1. **No VPC/subnet creation** — Accepts `VpcId`, `PrivateSubnet1Id/2Id/3Id` and deploys into a caller-supplied VPC.
2. **Optional endpoint creation** — `CreateVpcEndpoints` flag (default `true`) skips creating the four interface endpoints (ssm, ssmmessages, logs, secretsmanager) if the buyer's VPC already has them. Duplicates fail the deploy. *(This replaces the original two-flag design — see Phase 1.)*
3. **`BoltAdvertisedDNS`** — Optional stable DNS alias for the Bolt advertised address and cert SAN. Used in production when the NLB DNS must not be pinned in certs. Testing deferred — requires a Route 53 zone and is independent of VPC ownership.

---

## Phase 0 — VPC lifecycle scripts (prerequisite)

`create-test-vpc.sh` and `teardown-test-vpc.sh` must exist before Phase 1 can be validated. They have no dependency on the template changes and can be written and reviewed independently. Both live in `neo4j-ee/scripts/` — details in the [New scripts](#new-scripts) section below.

---

## Phase 1 — Template design fix

This must land before the orchestrator is written. The automated Path B test depends on it being correct.

### Root cause

`VpcEndpointSecurityGroup` is unconditionally created and always published as `vpc-endpoint-sg-id` in the SSM contract. When endpoint creation is skipped, no endpoints use that SG, so:

- Neo4j instances and bastion cannot reach the pre-existing endpoints (their SGs are not in the pre-existing endpoint SG's ingress).
- The published `vpc-endpoint-sg-id` points to a SG that gates nothing. Downstream applications that follow the contract and wire to it gain no endpoint access.

The original two-flag design (`CreateSSMEndpoint` + `CreateSecretsManagerEndpoint`) makes this worse: the four possible states include two half-managed cases (SSM=false, SM=true and vice versa) that cannot be correctly wired with a single `vpc-endpoint-sg-id` — one set of endpoints would be in the template's SG, the other in the customer's. Enterprise customers with pre-existing endpoints virtually always have a single shared endpoint SG covering all four interface endpoints.

There is also an existing bug in `VpcEndpointSecurityGroup`: its ingress currently sources from `Neo4jExternalSecurityGroup`, but that SG is for NLB/external traffic (ports 7474/7687 from `AllowedCIDR`). Neo4j instances are assigned both `Neo4jExternalSecurityGroup` and `Neo4jInternalSecurityGroup` (see `asg-existing-vpc.yaml`). The correct source for the instances' own AWS API calls (SSM, Secrets Manager, CloudWatch Logs) is `Neo4jInternalSecurityGroup`. This fix is applied in both the `CreateVpcEndpoints=true` and `=false` paths.

`S3GatewayEndpoint` is also present in `networking-existing-vpc.yaml` but is not needed — gateway endpoints do not require security groups or `PrivateDnsEnabled`, and NAT handles S3 traffic. It is removed as part of this phase.

### Fix

Replace the two flags with a single `CreateVpcEndpoints` parameter and add `ExistingEndpointSgId`. A CFN `Rules` block (placed between `Parameters:` and `Conditions:`, per canonical CFN section order) enforces that `ExistingEndpointSgId` is non-empty when `CreateVpcEndpoints=false`.

When `CreateVpcEndpoints=false`:
- `VpcEndpointSecurityGroup` is not created (conditional).
- Two `AWS::EC2::SecurityGroupIngress` resources wire `Neo4jBastionSecurityGroup` and `Neo4jInternalSecurityGroup` into `ExistingEndpointSgId` (ingress 443). Stack deletion removes these rules cleanly.
- The SSM contract publishes `ExistingEndpointSgId` as `vpc-endpoint-sg-id` — the correct, functional SG for downstream apps.

When `CreateVpcEndpoints=true`:
- `VpcEndpointSecurityGroup` is created as before, but its ingress sources are corrected from `Neo4jExternalSecurityGroup` to `Neo4jInternalSecurityGroup` for the instances' source (bastion source is unchanged).

### Files changed (existing-vpc partials only)

| File | Change |
|---|---|
| `templates/src/parameters-existing-vpc.yaml` | Replace `CreateSSMEndpoint` + `CreateSecretsManagerEndpoint` with `CreateVpcEndpoints` (true/false, default `true`). Add `ExistingEndpointSgId` (String, default `''`). |
| `templates/src/conditions-existing-vpc.yaml` | Replace two conditions with single `CreateVpcEndpoints: !Equals [!Ref CreateVpcEndpoints, 'true']`. |
| `templates/src/security-groups-existing-vpc.yaml` | (1) Add `Condition: CreateVpcEndpoints` to `VpcEndpointSecurityGroup`. (2) Fix existing `VpcEndpointSecurityGroup` ingress: replace `Neo4jExternalSecurityGroup` source with `Neo4jInternalSecurityGroup`. (3) Add two conditional `SecurityGroupIngress` resources (condition `!Not [CreateVpcEndpoints]`) wiring `Neo4jBastionSecurityGroup` and `Neo4jInternalSecurityGroup` into `ExistingEndpointSgId`. |
| `templates/src/networking-existing-vpc.yaml` | (1) Replace all `CreateSSMEndpoint` / `CreateSecretsManagerEndpoint` condition references with `CreateVpcEndpoints`. (2) Remove `S3GatewayEndpoint` resource entirely. |
| `templates/src/stack-config-existing-vpc.yaml` | `vpc-endpoint-sg-id` value: `!If [CreateVpcEndpoints, !GetAtt VpcEndpointSecurityGroup.GroupId, !Ref ExistingEndpointSgId]` |
| `templates/src/metadata-existing-vpc.yaml` | Update parameter group and labels to reflect new parameters. |
| `templates/src/outputs-existing-vpc.yaml` | Add `Neo4jBastionSecurityGroupId` output (value: `!GetAtt Neo4jBastionSecurityGroup.GroupId`). Required by the `test-existing-vpc.sh` orchestrator to wire the bastion SG into a pre-existing endpoint SG during Path B. |
| New: `templates/src/rules-existing-vpc.yaml` | CFN `Rules:` block — assert `ExistingEndpointSgId` is non-empty when `CreateVpcEndpoints=false`. |
| `templates/build.py` | Add `Rules:\n` section and `rules-existing-vpc.yaml` to `_assemble_existing_vpc()`, inserted between `Parameters:` and `Conditions:` (canonical CFN section order). Only the existing-vpc assembler gets this section. |

Regenerate with `python templates/build.py` after all partial edits.

---

## Phase 2 — Remaining gaps

### 1. `config.py` rejects `ExistingVpc` mode

`validate-private/src/validate_private/config.py` line 59:

```python
if deployment_mode != "Private":
    raise ValueError("validate-private only supports Private-mode stacks...")
```

`deploy.py` writes `DeploymentMode = ExistingVpc` to `.deploy/<stack>.txt`. The validator exits before running any checks.

**Fix:** Change the guard to `if deployment_mode not in ("Private", "ExistingVpc"):`. No other validator changes needed — `bastion_id`, `nlb_dns`, `password`, and `install_apoc` resolve from identical field names in both templates' outputs.

### 2. `deploy.py` does not pass `CreateVpcEndpoints` or `ExistingEndpointSgId`

`deploy.py` currently passes `VpcId` and subnet IDs for `ExistingVpc` mode but no endpoint parameters, so CFN falls back to the template defaults. This is an **addition** — these flags do not exist yet in `deploy.py`.

**Fix:** Add to `parse_args()`:

```python
p.add_argument("--create-vpc-endpoints", default="true", choices=["true", "false"])
p.add_argument("--existing-endpoint-sg-id", metavar="SG_ID", default="")
```

Add validation in `main()`:

```python
if args.mode == "ExistingVpc" and args.create_vpc_endpoints == "false" and not args.existing_endpoint_sg_id:
    sys.exit("ERROR: --existing-endpoint-sg-id is required when --create-vpc-endpoints false")
```

In the `ExistingVpc` cfn_params block, append:

```python
{"ParameterKey": "CreateVpcEndpoints", "ParameterValue": args.create_vpc_endpoints},
```

And when `ExistingEndpointSgId` is provided:

```python
if args.existing_endpoint_sg_id:
    cfn_params.append({"ParameterKey": "ExistingEndpointSgId", "ParameterValue": args.existing_endpoint_sg_id})
```

Write both values into the outputs file so teardown tooling knows what was provisioned.

### 3. No prerequisite VPC tooling

Addressed in Phase 0 — `create-test-vpc.sh` and `teardown-test-vpc.sh` are implemented and reviewed first so Phase 1 has a real VPC to deploy against.

### 4. `AllowedCIDR` default does not match a test VPC

`deploy.py` defaults `AllowedCIDR=10.0.0.0/16` for `ExistingVpc` mode. If the test VPC uses a different CIDR, the security group rule does not cover cluster traffic. The test VPC script must write the CIDR to its output file and the orchestrator must pass `--allowed-cidr` explicitly.

---

## Test matrix

| Path | When to run | Servers | `CreateVpcEndpoints` | What it tests |
|------|-------------|---------|----------------------|---------------|
| A — fresh VPC | Every CI run (gate) | 3 | `true` | Stack deploys into a new VPC; template creates all four endpoints |
| B — VPC with endpoints | Weekly / pre-release | 1 | `false` | Template skips endpoint creation; `ExistingEndpointSgId` is passed; SSM contract publishes the correct SG |

**Core `validate-private` checks are VPC-agnostic** — Bolt connectivity, server edition, listen address, memory config, data directory, APOC, failover, and resilience all run Cypher through the bastion. They have no dependency on VPC topology and work identically for both paths.

**Preflight endpoint reachability** (checks 8–12 in `preflight.sh`) verify the bastion can reach each endpoint hostname. For Path A this is automatic. For Path B the test VPC's pre-existing endpoints must allow the bastion's SG — the orchestrator adds one `authorize-security-group-ingress` call (ingress 443 from the bastion SG to the pre-existing endpoint SG) immediately after the stack deploys and before preflight runs. The bastion SG ID is read from the `Neo4jBastionSecurityGroupId` CFN stack output (added to `outputs-existing-vpc.yaml` in Phase 1).

**`sample-private-app`** is an optional post-Path-A step to verify that `vpc-id`, `external-sg-id`, and `vpc-endpoint-sg-id` are published correctly. Not required for the core validate-private pass.

---

## New scripts

All scripts live in `neo4j-ee/scripts/`. `create-test-vpc.sh` and `teardown-test-vpc.sh` are Phase 0. `test-existing-vpc.sh` is Phase 3 (after Phase 2 gaps are closed).

### `create-test-vpc.sh`

Creates a minimal private-networking VPC. Key behaviors:

- Accepts `--region` (required) and `--with-endpoints` (for Path B).
- Creates VPC (`10.42.0.0/16`), 3 public + 3 private subnets across 3 AZs (enumerated via `describe-availability-zones --state available` — no hardcoded AZ suffixes), IGW, 3 NAT gateways with EIPs, route tables. No S3 gateway endpoint — NAT handles S3 traffic correctly for a test run.
- When `--with-endpoints`: creates `ssm`, `ssmmessages`, `logs`, `secretsmanager` interface endpoints in the private subnets with `PrivateDnsEnabled=true`; creates a shared endpoint security group with ingress 443 from the VPC CIDR.
- Writes `.deploy/vpc-<ts>.txt` with all resource IDs so teardown needs no additional `describe-*` calls:

  ```
  VpcId               = vpc-...
  Subnet1Id           = subnet-...
  Subnet2Id           = subnet-...
  Subnet3Id           = subnet-...
  VpcCidr             = 10.42.0.0/16
  Region              = us-east-1
  WithEndpoints       = true|false
  EndpointSgId        = sg-...     (only when WithEndpoints=true)
  PublicSubnet1Id     = subnet-...
  PublicSubnet2Id     = subnet-...
  PublicSubnet3Id     = subnet-...
  NatGateway1Id       = nat-...
  NatGateway2Id       = nat-...
  NatGateway3Id       = nat-...
  Eip1AllocationId    = eipalloc-...
  Eip2AllocationId    = eipalloc-...
  Eip3AllocationId    = eipalloc-...
  RouteTable1Id       = rtb-...
  RouteTable2Id       = rtb-...
  RouteTable3Id       = rtb-...
  IgwId               = igw-...
  ```

### `teardown-test-vpc.sh`

Reads `.deploy/vpc-<ts>.txt` and deletes in reverse order:

1. Interface endpoints (if `WithEndpoints=true`) — wait for `deleted` state
2. NAT gateways — wait for `deleted` state (60–90 s)
3. Release EIPs
4. Delete subnets and route table associations
5. Delete private route tables (main RT is deleted with the VPC)
6. Detach and delete IGW
7. Delete VPC
8. Remove `.deploy/vpc-<ts>.txt`

Defaults to the most-recently modified `vpc-*.txt` in `.deploy/`; accepts an optional VPC stack name argument.

### `test-existing-vpc.sh` (orchestrator — Phase 3)

```bash
scripts/test-existing-vpc.sh --region us-east-1 --path a   # Path A only
scripts/test-existing-vpc.sh --region us-east-1 --path b   # Path B only
scripts/test-existing-vpc.sh --region us-east-1            # both paths sequentially
```

Sequence per path — `trap ERR EXIT` runs teardown steps on any failure so no resources are left stranded:

**Path A:**

```
1. scripts/create-test-vpc.sh --region <region>
2. deploy.py --mode ExistingVpc --region <region> --number-of-servers 3
     --vpc-id <VpcId> --subnet-1 <Subnet1Id> --subnet-2 <Subnet2Id> --subnet-3 <Subnet3Id>
     --allowed-cidr <VpcCidr> --create-vpc-endpoints true
3. validate-private/scripts/preflight.sh <stack>
4. cd validate-private && uv run validate-private --stack <stack>
5. teardown.sh --delete-volumes <stack>
6. scripts/teardown-test-vpc.sh <vpc>
```

**Path B:**

```
1. scripts/create-test-vpc.sh --region <region> --with-endpoints
2. deploy.py --mode ExistingVpc --region <region> --number-of-servers 1
     --vpc-id <VpcId> --subnet-1 <Subnet1Id>
     --allowed-cidr <VpcCidr>
     --create-vpc-endpoints false --existing-endpoint-sg-id <EndpointSgId>
3. Wire bastion SG into pre-existing endpoint SG:
     aws ec2 authorize-security-group-ingress
       --group-id <EndpointSgId>
       --protocol tcp --port 443
       --source-group <Neo4jBastionSecurityGroupId>
       --region <region>
4. validate-private/scripts/preflight.sh <stack>
5. cd validate-private && uv run validate-private --stack <stack>
6. teardown.sh --delete-volumes <stack>
7. scripts/teardown-test-vpc.sh <vpc>
```

The bastion SG ID is read from the `Neo4jBastionSecurityGroupId` CFN stack output after step 2.

---

## Region notes

All seven `SUPPORTED_REGIONS` in `deploy.py` have at least 3 AZs. No region pinning is required. AZ enumeration in `scripts/create-test-vpc.sh` must use `describe-availability-zones --state available` — never hardcode AZ suffixes.
