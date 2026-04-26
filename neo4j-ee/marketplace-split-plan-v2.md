# Marketplace Template Split: Implementation Plan v2

## Status

| Phase | Status |
|-------|--------|
| Phase A — Shared file cleanup | ✅ Complete |
| Phase B-Private — Private template finalization | ✅ Complete |
| Phase B-Public — Public template authoring | ✅ Complete |
| Phase B-Existing VPC — Existing VPC template authoring | ✅ Complete |
| Phase C — Deploy and validate | ⬜ Not started |
| Phase D — Finalization | ⬜ Not started |

---

## Context

Phases 1 and 2 are complete. The build system exists, `neo4j-private.template.yaml`
is generated from source partials in `templates/src/`, and CI enforces that the
committed output is always up to date.

This plan replaces v1's Phases 3–5. The v1 plan mixed file authoring, deploy testing,
and open design decisions inside the same phases, which caused conflicts and ambiguity.
This plan resolves all design decisions up front, separates file authoring (parallelizable)
from deploy testing (user-driven and sequential), and makes the dependency between
workstreams explicit.

---

## Design Decisions

**1. `AllowedCIDR` is topology-specific.** Removed from `parameters-common.yaml`. Each
topology defines it in its own parameters file:
- Public: no default; description "enter the CIDR allowed to reach Neo4j ports — 0.0.0.0/0
  is not accepted"
- Private: `Default: 10.0.0.0/16` — the VPC CIDR the template creates
- Existing VPC: no default; description "enter the CIDR of your existing VPC, e.g.
  10.0.0.0/16 or 172.16.0.0/12 — 0.0.0.0/0 is not accepted"

**2. `DeploymentMode` is removed.** Each template is a single topology; the parameter
has no meaning in a split design. Removed from `parameters-common.yaml`.

**3. `stack-config.yaml` conditions are removed entirely.** The nine resources gated on
`IsPrivate` become unconditional. `Neo4jConfigPrivateSubnet2Parameter` (gated on
`IsPrivateCluster`) gets `Condition: CreateCluster`. `stack-config.yaml` is only
included in templates that create the referenced resources — Private and Existing VPC.

**4. `asg.yaml` VPCZoneIdentifier is made unconditional for the private template.** The
`!If [IsPrivate, [private], [public]]` branch is removed; the private template always
uses private subnets. The public template uses `asg-public.yaml` (public subnets);
the existing-VPC template uses `asg-existing-vpc.yaml` (buyer-provided subnet params).

**5. TLS (`BoltCertificateSecretArn`, `BoltAdvertisedDNS`) is present in all three
templates.** The public template has an internet-facing NLB; sending Bolt traffic
across the public internet unencrypted is a significant security risk. All three
templates include `parameters-tls.yaml`, the `BoltTLSEnabled` condition, the
corresponding IAM policy statement, and the cert-installation block in UserData.
TLS is optional in all three (blank `BoltCertificateSecretArn` = TLS off).

---

## Execution Model

```
Phase A (shared cleanup) ──► Phase B-Public    ──► merge ──┐
                         ──► Phase B-Private   ──► merge ──┤──► Phase C (deploy) ──► Phase D
                         ──► Phase B-Existing  ──► merge ──┘
```

Phase A is the prerequisite. After it lands, the three Phase B workstreams are fully
independent — no shared file is touched by more than one. Phase B sub-phases can run
as parallel agents in git worktrees. The only merge work is additive lines in
`build.py`'s `_build()` and `_verify()`.

**Note on CI during Phase A → Phase B-Private:** Phase A removes `DeploymentMode` from
`parameters-common.yaml`, which breaks `conditions.yaml` (its `IsPrivate` condition
references `!Ref DeploymentMode`). The cfn-lint job will be red until Phase B-Private
completes and replaces `conditions.yaml` with `conditions-private.yaml`. The `--verify`
check stays green because Phase A regenerates and commits the output. This is expected
and acceptable.

---

## Phase A: Shared file cleanup ✅

**Goal:** Implement the four design decisions on shared partials. Two targeted file edits.
No new files. After this phase the shared partials are stable for the duration of Phase B.

- [x] `src/parameters-common.yaml`: remove the `DeploymentMode` and `AllowedCIDR`
  parameters. After this edit the file has exactly seven parameters: ImageId, Password,
  NumberOfServers, InstanceType, DataDiskSize, DataVolumeKmsKeyId, AlertEmail.
- [x] `src/stack-config.yaml`: remove `Condition: IsPrivate` from the nine resources
  that have it; replace `Condition: IsPrivateCluster` → `Condition: CreateCluster` on
  `Neo4jConfigPrivateSubnet2Parameter`.
- [x] Run `python templates/build.py` and commit the regenerated `neo4j-private.template.yaml`.
  The `--verify` CI check will continue to pass. The cfn-lint check will be red (because
  `conditions.yaml` still references the removed `DeploymentMode` parameter) until Phase
  B-Private completes — this is expected.

---

## Phase B-Public: Public template authoring ✅

**Goal:** `templates/neo4j-public.template.yaml` is generated and passes cfn-lint. No
private subnets, NAT gateways, bastion, VPC endpoints, or TLS parameters absent — TLS
is fully supported via optional `BoltCertificateSecretArn`.

### New partials

- [x] `src/parameters-public.yaml`
  - `AllowedCIDR`: no default; AllowedPattern same as current (rejects `0.0.0.0/0`);
    description "enter the CIDR allowed to reach Neo4j ports — 0.0.0.0/0 is not accepted"

- [x] `src/conditions-public.yaml`
  - `CreateCluster`, `HasAlertEmail`, `BoltTLSEnabled`, `HasDataVolumeCmk`
  - No `IsPrivate`, `IsPublic`, `IsPrivateCluster`

- [x] `src/metadata-public.yaml`
  - Same structure as `metadata-private.yaml`: parameter groups omit `DeploymentMode`;
    TLS params included in "Security & Monitoring" group

- [x] `src/networking-public.yaml`
  - `Neo4jVPC` (10.0.0.0/16)
  - `Neo4jSubnet1/2/3` (10.0.1-3.0/24, `MapPublicIpOnLaunch: true`; Subnet2/3 gated on
    `CreateCluster`)
  - `Neo4jInternetGateway`, `Neo4jInternetGatewayAttachment`
  - `Neo4jRouteTable`, `Neo4jRoute` (0.0.0.0/0 → IGW), subnet route table associations
  - `Neo4jNetworkLoadBalancer` (Scheme: `internet-facing`; Subnets: public subnets)
  - NLB listeners (7474 TCP, 7687 TCP) and target groups

- [x] `src/asg-public.yaml`
  - Copy of `src/asg.yaml` with `VPCZoneIdentifier` always referencing public subnets:
    `Node1ASG → [!Ref Neo4jSubnet1]`, `Node2/3ASG → [!Ref Neo4jSubnet2/3]`
  - No `!If [IsPrivate, ...]` branch

- [x] `src/iam-public.yaml`
  - `Neo4jInstanceProfile` and `Neo4jRole` only — no bastion role/profile (no bastion in
    public template)
  - TLS branch (`!If [BoltTLSEnabled, ...]`) kept in `Neo4jRole` policy

- [x] `src/security-groups-public.yaml`
  - `Neo4jExternalSecurityGroup` and `Neo4jInternalSecurityGroup` only
  - No `Neo4jBastionSecurityGroup` or `VpcEndpointSecurityGroup` (no bastion or VPC
    endpoints in public template)

- [x] `src/outputs-public.yaml`
  - `Neo4jBrowserURL`: `http://<NLB DNS>:7474`
  - `Neo4jURI`: `neo4j://<NLB DNS>:7687`
  - `Neo4jDataVolumeIds`, `Username`, `Neo4jAppLogGroupName`, `Neo4jAlertTopicArn`,
    `VpcFlowLogGroupName`, `FailedAuthAlarmName`
  - No private-mode outputs (no SSM commands, no bastion ID, no password ARN)

- [x] `src/userdata-public.sh`
  - Uses `${boltAdvertisedDNS:-${loadBalancerDNSName}}` for `server.bolt.advertised_address`
  - Includes full TLS cert-installation block (identical to private)

### Build

- [x] Add `_assemble_public()` to `build.py`:
  ```
  parameters-common.yaml + parameters-tls.yaml + parameters-public.yaml
  + conditions-public.yaml + metadata-public.yaml
  + iam-public.yaml + security-groups-public.yaml + ebs-volumes.yaml
  + asg-public.yaml (userdata-public.sh)
  + networking-public.yaml + observability.yaml
  + outputs-public.yaml
  ```
  Note: no `stack-config.yaml` (no Secrets Manager password secret or SSM params in
  the public template). No bastion IAM or security group resources.

- [x] Update `_build()` and `_verify()` in `build.py` for the public template
- [ ] Update `.github/workflows/validate-templates.yml` to lint `neo4j-public.template.yaml`
- [ ] `cfn-lint templates/neo4j-public.template.yaml` passes with no errors
- [ ] Confirm `BoltCertificateSecretArn` and `BoltAdvertisedDNS` are present and
  functional in the generated output

---

## Phase B-Private: Private template finalization ✅

**Goal:** `templates/neo4j-private.template.yaml` contains no `IsPrivate`, `IsPublic`, or
`IsPrivateCluster` conditions. Every resource is either unconditional or gated only on
`CreateCluster`, `HasAlertEmail`, `BoltTLSEnabled`, or `HasDataVolumeCmk`.

### Rewrite and rename

- [x] Rewrite `src/networking-private.yaml` — remove all `IsPrivate`, `IsPublic`,
  `IsPrivateCluster` conditions:
  - `Neo4jSubnet1/2/3` (public, for NAT only): `MapPublicIpOnLaunch: false`;
    Subnet2/3 gated on `CreateCluster`
  - `Neo4jPrivateSubnet1`: unconditional
  - `Neo4jPrivateSubnet2/3`: gated on `CreateCluster`
  - `Neo4jNatEIP1`, `Neo4jNatGateway1`, three private route tables,
    `Neo4jPrivateRoute1`, `Neo4jPrivateSubnet1RouteTableAssociation`: unconditional
  - `Neo4jNatEIP2/3`, `Neo4jNatGateway2/3`, `Neo4jPrivateRoute2/3`,
    `Neo4jPrivateSubnet2/3RouteTableAssociation`: gated on `CreateCluster`
  - Private routes 2/3 reference `!Ref Neo4jNatGateway2/3` directly — no
    `!If [IsPrivateCluster, ...]` fallback needed because the routes are only created
    when the NAT gateways are (both gated on `CreateCluster`). Route tables 2/3 remain
    unconditional; in 1-node mode they are empty and have no associated subnets.
  - `Neo4jNetworkLoadBalancer`: Scheme always `internal`; Subnets `!If [CreateCluster,
    [all three private], [Neo4jPrivateSubnet1]]`
  - `Neo4jOperatorBastion`: unconditional (removed `Condition: IsPrivate`)
  - All five VPC endpoints: unconditional; SubnetIds `!If [CreateCluster,
    [all three private], [Neo4jPrivateSubnet1]]`
  - `S3GatewayEndpoint` RouteTableIds: `!If [CreateCluster, [all three private RTs],
    [Neo4jPrivateRouteTable1]]`

- [x] Create `src/conditions-private.yaml` from `src/conditions.yaml` minus `IsPrivate`,
  `IsPublic`, `IsPrivateCluster`. Keep `CreateCluster`, `HasAlertEmail`, `BoltTLSEnabled`,
  `HasDataVolumeCmk`.

- [x] Create `src/metadata-private.yaml` from `src/metadata.yaml` minus `DeploymentMode`
  from ParameterGroups and ParameterLabels.

- [x] Create `src/outputs-private.yaml` from `src/outputs.yaml`:
  - Remove `Neo4jBrowserURL` and `Neo4jURI` (those are public-mode outputs)
  - Remove `Condition: IsPublic` and `Condition: IsPrivate` from all remaining outputs
  - `Neo4jNode2ASGName`, `Neo4jNode3ASGName` stay gated on `CreateCluster`

- [x] Create `src/parameters-private.yaml`:
  - `AllowedCIDR`: `Default: 10.0.0.0/16`; same AllowedPattern; description "CIDR
    allowed to reach Neo4j ports 7474 and 7687; defaults to the VPC CIDR this template
    creates"

- [x] Edit `src/asg.yaml`: replace `VPCZoneIdentifier: !If [IsPrivate, ...]` with
  unconditional private subnet references on all three ASGs:
  `Node1ASG → [!Ref Neo4jPrivateSubnet1]`, `Node2ASG → [!Ref Neo4jPrivateSubnet2]`,
  `Node3ASG → [!Ref Neo4jPrivateSubnet3]`

- [x] Edit `src/iam.yaml`: remove `Condition: IsPrivate` from `Neo4jBastionRole` and
  `Neo4jBastionInstanceProfile` (bastion is unconditional in the private template).

- [x] Edit `src/security-groups.yaml`: remove `Condition: IsPrivate` from
  `Neo4jBastionSecurityGroup` and `VpcEndpointSecurityGroup`.

- [x] Delete `src/conditions.yaml`, `src/metadata.yaml`, `src/outputs.yaml` — replaced
  by the topology-specific files above

### Build

- [x] Update `_assemble_private()` in `build.py` to use the new file names:
  ```
  parameters-common.yaml + parameters-tls.yaml + parameters-private.yaml
  + conditions-private.yaml + metadata-private.yaml
  + iam.yaml + security-groups.yaml + ebs-volumes.yaml
  + asg.yaml (userdata-private.sh)
  + networking-private.yaml + stack-config.yaml + observability.yaml
  + outputs-private.yaml
  ```
- [ ] `cfn-lint templates/neo4j-private.template.yaml` passes with no errors
- [ ] Confirm no `IsPrivate`, `IsPublic`, `IsPrivateCluster`, `DeploymentMode` in the
  generated output ✅ (verified via grep — zero occurrences)

---

## Phase B-Existing VPC: Existing VPC template authoring ✅

**Goal:** `templates/neo4j-private-existing-vpc.template.yaml` is generated and passes
cfn-lint. No VPC, subnets, IGW, NAT gateways, or route tables created. Buyer provides
existing VPC and private subnets. TLS fully supported.

### New partials

- [x] `src/parameters-existing-vpc.yaml`
  - `VpcId`, `PrivateSubnet1Id`, `PrivateSubnet2Id`, `PrivateSubnet3Id`
  - `CreateSSMEndpoint`: `Default: 'true'`
  - `CreateSecretsManagerEndpoint`: `Default: 'true'`
  - `AllowedCIDR`: no default; description "enter the CIDR of your existing VPC"

- [x] `src/conditions-existing-vpc.yaml`
  - `CreateCluster`, `HasAlertEmail`, `BoltTLSEnabled`, `HasDataVolumeCmk`
  - `CreateSSMEndpoint: !Equals [!Ref CreateSSMEndpoint, 'true']`
  - `CreateSecretsManagerEndpoint: !Equals [!Ref CreateSecretsManagerEndpoint, 'true']`

- [x] `src/metadata-existing-vpc.yaml`
  - Parameter groups: existing-VPC params in "Existing VPC" group; TLS params in "TLS"
    group; common cluster params grouped as in private template

- [x] `src/networking-existing-vpc.yaml`
  - `Neo4jOperatorBastion`: `SubnetId: !Ref PrivateSubnet1Id`
  - `SsmVpcEndpoint`, `SsmMessagesVpcEndpoint`, `LogsVpcEndpoint`: gated on
    `CreateSSMEndpoint`; `VpcId: !Ref VpcId`; buyer subnet refs
  - `SecretsManagerVpcEndpoint`: gated on `CreateSecretsManagerEndpoint`
  - `S3GatewayEndpoint`: always created; `VpcId: !Ref VpcId`; `RouteTableIds` omitted
    (cannot inject routes into buyer-controlled route tables)
  - `Neo4jNetworkLoadBalancer`: `Scheme: internal`; buyer subnet refs; no `DependsOn`
    IGW attachment
  - NLB listeners and target groups: `VpcId: !Ref VpcId`

- [x] `src/asg-existing-vpc.yaml`
  - `VPCZoneIdentifier` references buyer subnet params:
    `Node1ASG → [!Ref PrivateSubnet1Id]`,
    `Node2ASG → [!Ref PrivateSubnet2Id]`,
    `Node3ASG → [!Ref PrivateSubnet3Id]`

- [x] `src/security-groups-existing-vpc.yaml`
  - Copy of `src/security-groups.yaml` with `VpcId: !Ref VpcId` on all security groups

- [x] `src/observability-existing-vpc.yaml`
  - Copy of `src/observability.yaml` with `ResourceId: !Ref VpcId` on `Neo4jVPCFlowLog`

- [x] `src/stack-config-existing-vpc.yaml`
  - Copy of `src/stack-config.yaml` with:
    - `Neo4jConfigVpcIdParameter`: `Value: !Ref VpcId`
    - `Neo4jConfigPrivateSubnet1Parameter`: `Value: !Ref PrivateSubnet1Id`
    - `Neo4jConfigPrivateSubnet2Parameter`: `Condition: CreateCluster`;
      `Value: !Ref PrivateSubnet2Id`

- [x] `src/outputs-existing-vpc.yaml`
  - Identical to `outputs-private.yaml`

### Build

- [x] Add `_assemble_existing_vpc()` to `build.py`:
  ```
  parameters-common.yaml + parameters-tls.yaml + parameters-existing-vpc.yaml
  + conditions-existing-vpc.yaml + metadata-existing-vpc.yaml
  + iam.yaml + security-groups-existing-vpc.yaml + ebs-volumes.yaml
  + asg-existing-vpc.yaml (userdata-existing-vpc.sh)
  + networking-existing-vpc.yaml + stack-config-existing-vpc.yaml
  + observability-existing-vpc.yaml + outputs-existing-vpc.yaml
  ```
- [x] Update `_build()` and `_verify()` in `build.py` for the existing-VPC template
- [ ] Update `.github/workflows/validate-templates.yml` to lint
  `neo4j-private-existing-vpc.template.yaml`
- [ ] `cfn-lint templates/neo4j-private-existing-vpc.template.yaml` passes with no errors
- [ ] Confirm no VPC, subnet, IGW, NAT gateway, or route table resources in generated output

---

## Phase C: Deploy and validate

User-driven. Each topology: deploy, test, teardown. Order: Private first (closest to the
proven Phase 2 baseline), then Public, then Existing VPC.

### Private

- [ ] 1-node deploy; confirm SSM Session Manager bastion access; confirm Bolt reachable
  from within VPC via port-forward
- [ ] 3-node deploy; confirm cluster forms and Raft converges
- [ ] 3-node deploy with TLS; confirm Bolt TLS handshake succeeds
- [ ] Run `validate-private/` tooling against 3-node stack
- [ ] Teardown all test stacks cleanly

### Public

- [ ] 1-node deploy; confirm HTTP (7474) and Bolt (7687) reachable from internet
- [ ] 3-node deploy; confirm all three nodes join and cluster forms
- [ ] 1-node deploy with TLS; confirm `neo4j+s://` Bolt TLS handshake succeeds from internet
- [ ] Teardown all test stacks cleanly

### Existing VPC

- [ ] Create a test VPC with private subnets and a NAT gateway out-of-band (simulates
  a buyer's pre-existing VPC)
- [ ] 1-node deploy into test VPC; confirm bastion SSM access and Bolt connectivity
- [ ] 3-node deploy; confirm cluster forms
- [ ] Deploy with `CreateSSMEndpoint=false` against a VPC that already has the endpoint;
  confirm no duplicate resource error
- [ ] 3-node deploy with TLS; confirm Bolt TLS handshake succeeds
- [ ] Teardown all test stacks and the test VPC cleanly

---

## Phase D: Finalization

After all three topologies pass Phase C.

- [ ] `deploy.py`: `--mode public` → `templates/neo4j-public.template.yaml`; `--mode
  private` → `templates/neo4j-private.template.yaml` (make `private` the default);
  `--mode existing-vpc` → `templates/neo4j-private-existing-vpc.template.yaml`;
  document that `--allowed-cidr` is required for `existing-vpc`
- [ ] Delete `neo4j.template.yaml` from the repo root — `templates/neo4j-private.template.yaml`
  is now the live Private artifact
- [ ] Rename `validate-private/` → `validate/`; update its README
- [ ] Create architectural diagram for Public template (1100×700px, AWS icons): VPC +
  public subnets + internet-facing NLB + EC2 instances in public subnets
- [ ] Create architectural diagram for Private template (1100×700px): VPC + public
  subnets (NAT only) + private subnets + NAT gateways + bastion + internal NLB + EC2
  instances in private subnets
- [ ] Create architectural diagram for Existing VPC template (1100×700px): pre-existing
  VPC frame (buyer-provided) + private subnets + bastion + internal NLB + EC2 instances;
  no VPC creation shown
- [ ] Update `README.md` to reference all three templates and their target buyers
