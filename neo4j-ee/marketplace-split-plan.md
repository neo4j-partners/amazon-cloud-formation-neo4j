# Marketplace Template Split: Phased Implementation Plan

## Key Principle: Naming

Never name files or tests using the word "phase" or based on plan phases. Use descriptive names based on actual functionality. For example: `parameters-common.yaml` not `phase2-parameters.yaml`, `userdata-private.sh` not `phase2-script.sh`, `test_assembly.py` not `test_phase2.py`.

## Core Goals

The current Enterprise Edition CloudFormation template deploys two architecturally distinct topologies from a single file. A `DeploymentMode` parameter branches the template into either a public internet-facing cluster or a private cluster with NAT gateways, VPC endpoints, and an SSM bastion. This causes three concrete problems.

First, the single architectural diagram required by AWS Marketplace cannot accurately represent both topologies. One diagram must omit either the NAT infrastructure or the internet-facing NLB, so whichever buyer chooses the other mode is looking at a diagram that does not match what the template actually deploys.

Second, the parameter surface is misleading. A buyer in Public mode sees parameters for VPC endpoints and Secrets Manager TLS certificates that have no effect on their deployment. A buyer in Private mode sees nothing about the CIDR of the VPC their cluster will land in until they read the description text.

Third, the conditional branching (`IsPrivate`, `IsPublic`, `IsPrivateCluster`) makes the template hard to review, hard to test exhaustively, and hard to explain to the Marketplace review team.

The goal of this work is to replace the single branching template with three topology-specific templates, each representing a distinct buyer profile and deployable resource set, within a single Marketplace product listing.

---

## Key Decisions

### Decision 1: One Marketplace listing, three templates

AWS Marketplace allows up to three CloudFormation templates per AMI-based product listing. Each template requires its own architectural diagram. Using three topology-specific templates within one listing achieves clear buyer selection and accurate diagrams without the operational cost of maintaining two separate products. A second listing is only warranted if Neo4j pursues a compliance certification (FedRAMP, HIPAA) that must attach to a specific product, or if AWS account-level visibility controls are needed. Neither applies today.

### Decision 2: The three templates and their names

| Template file | Marketplace display name | Target buyer |
|---|---|---|
| `neo4j-public.template.yaml` | Public | Proof of concept, demos, evaluation |
| `neo4j-private.template.yaml` | Private | Production and staging, AWS-managed networking |
| `neo4j-private-existing-vpc.template.yaml` | Private, Existing VPC | Enterprise with pre-existing VPC infrastructure |

The "Private, Existing VPC" name is intentional. "Advanced Private" does not communicate the key distinction. A buyer whose network team controls which VPCs applications may use will not recognize "advanced" as the signal this template is for them. Template names in a Marketplace listing cannot be changed after buyers subscribe.

### Decision 3: Template 3 is a distinct architecture, not a Private variant

The argument against a third template is that it is just Private with different parameters. That is wrong. When a buyer provides an existing VPC, the template stops creating an entire layer of AWS resources: no VPC, no subnets, no internet gateway, no NAT gateways, no route tables, no VPC endpoints. The resources that set up private networking represent roughly a third of the current template. Removing them produces a structurally different template with a different diagram, a different parameter surface, and a different set of pre-deployment requirements on the buyer. Each topology warrants its own template slot and its own diagram.

### Decision 4: TLS is available in Private and Private, Existing VPC. It is not available in Public.

The current template supports optional TLS in all modes via `BoltCertificateSecretArn`. The split divides TLS by security posture, not networking complexity. Public mode targets evaluation deployments where certificate management adds friction without meaningful benefit. Both Private templates target production or regulated workloads where TLS is a legitimate and common requirement. The `BoltCertificateSecretArn` and `BoltAdvertisedDNS` parameters appear in Templates 2 and 3 as optional fields. Template 1 omits them.

### Decision 5: The build system prevents template drift; a diff report surfaces UserData drift

Three separate YAML files with shared IAM, security groups, and ASG resources will drift. For those sections, shared source partials under `templates/src/` assembled by `build.py` are the correct control — there is only one copy, so drift is structurally prevented.

UserData is different. The three templates have different CloudFormation parameter surfaces: the Public template has no TLS parameters, so a single script with `Fn::Sub` references to `BoltCertificateSecretArn` would be rejected at deploy time. Making one script work across all three would require stub parameters that pollute the buyer parameter UI, build-time stripping, or shell conditionals standing in for CF parameters — complexity paid on every future read of the script. Instead, each template has its own UserData script: `userdata-public.sh`, `userdata-private.sh`, `userdata-existing-vpc.sh`. The shared bootstrap logic stays visually identical across the three; the TLS block is simply present in private and existing-vpc and absent in public.

Drift across the three scripts is managed by a structured diff report in `build.py`. On every build, `build.py` diffs the three scripts and prints which sections differ and which are identical. This runs in CI on every pull request. It is not a gate that fails the build — intentional differences (TLS) should not break CI. It is a visibility control: divergence is reported immediately rather than discovered months later during a manual review.

### Decision 6: AllowedCIDR has no default in Template 3

AWS Marketplace requires that sellers not set default CIDR values that allow ingress to database ports from the public internet. That rule targets `0.0.0.0/0` style defaults. The reason Template 3 has no default at all is correctness: Template 2 defaults `AllowedCIDR` to `10.0.0.0/16` because it creates that VPC. Template 3 deploys into a VPC with an unknown CIDR. Any default we choose is likely wrong for most enterprise buyers, and a wrong default silently misconfigures the security group. The buyer must enter their VPC CIDR explicitly. The parameter description says: enter the CIDR of your existing VPC, for example `10.0.0.0/16` or `172.16.0.0/12`.

### Decision 7: Template 3 creates a bastion

The bastion is a purpose-built operator access point with no ingress rules, reachable only through AWS Systems Manager Session Manager. It is not optional. Enterprise buyers deploying into an existing VPC may have network topologies where no other path exists to reach the internal NLB. The template description must explain explicitly that the bastion is created, what it does, how it is accessed, and that it uses SSM rather than SSH. Buyers in environments with strict instance provisioning policies need this information before they launch.

### Decision 8: Template 3 VPC endpoint creation is optional per endpoint

Template 2 creates VPC interface endpoints for Systems Manager and Secrets Manager inside the VPC it creates. Template 3 deploys into a buyer-controlled VPC that may already have those endpoints. Creating a duplicate endpoint fails the deployment. Two boolean parameters, `CreateSSMEndpoint` and `CreateSecretsManagerEndpoint`, default to true. A buyer whose VPC already has centralized endpoint management sets the relevant parameter to false. The parameter description explains this clearly, including what happens if they leave the default when the endpoint already exists.

### Decision 9: NumberOfServers stays in all three templates, default 3

Public mode supports 1 or 3 nodes. Limiting Public to 1 node would prevent buyers who need to test clustering behavior before moving to Private. The AllowedCIDR parameter already blocks unrestricted public access. Instance costs are the buyer's decision. The default is 3 across all templates, consistent with Neo4j's recommended production cluster size.

### Decision 10: Partials are assembled by text-stitching, not YAML deep-merge

CloudFormation YAML uses non-standard tags (`!Ref`, `!Sub`, `!If`, `!GetAtt`) that standard YAML parsers do not handle without custom constructors. Deep-merging via PyYAML would require resolving these tags, adds failure modes, and strips comments and formatting from the output.

Instead, each partial file is a pre-indented YAML fragment for a specific CloudFormation section. `build.py` reads them as text and concatenates them under the appropriate section headers (`Parameters:`, `Resources:`, `Outputs:`). This is roughly 40 lines of Python, preserves all comments and formatting in the partials, and handles CF tags naturally because they are never parsed.

Partial files are indented at two spaces (matching CF section body indentation) and do not include the outer section key. For example, `parameters-common.yaml` begins with `  ImageId:` not `Parameters:\n  ImageId:`. `build.py` emits `Parameters:\n` then appends the file content.

### Decision 11: UserData scripts contain the script body only; build.py generates the CF preamble

The bash script in the LaunchTemplate UserData starts with a block of variable assignments that pull values from CloudFormation parameters and resource attributes (`password`, `nodeCount`, `loadBalancerDNSName`, `stackName`, `region`, `boltCertArn`, `boltAdvertisedDNS`). These assignments use `Ref:` and `Fn::GetAtt:` intrinsic functions and cannot live in a plain bash file.

The `src/userdata-*.sh` files begin after those assignments — they are the script body and are valid bash. `build.py` generates the CF preamble as a `Fn::Join` list of string literals and `Ref:`/`GetAtt:` nodes, then appends the `.sh` file content as a single string. The `.sh` files assume the preamble variables are already set and reference them as `$password`, `$nodeCount`, etc.

For `userdata-private.sh` and `userdata-existing-vpc.sh`, the preamble includes `boltCertArn` and `boltAdvertisedDNS`. For `userdata-public.sh`, those two assignments are omitted.

### Decision 12: Phase 2 produces neo4j-private.template.yaml only; deploy/delete/deploy.py update belong to later phases

Phase 2 establishes the build system and proves it produces a valid, lint-passing template. It does not deploy to AWS, does not delete the root template, and does not change `deploy.py`. The root `neo4j.template.yaml` remains the live deployable artifact until Phase 4 finalises the private template and its deploy/test cycle completes. Deployment and validation live in Phases 3, 4, and 5 respectively — one per topology.

The single Phase 2 output is `templates/neo4j-private.template.yaml`. It is semantically equivalent to the current template's Private mode and retains the `IsPrivate`/`IsPublic` conditional branching for now. That branching is removed in Phase 4 when the private networking partial is fully unconditional. The public and existing-VPC outputs remain stubs in `build.py` until Phases 3 and 5.

---

## Directory Structure Changes

The current layout keeps one template at the root alongside the operational scripts. Three templates alongside the same scripts creates clutter and makes it unclear which files are Marketplace deliverables and which are tooling. A `templates/` subdirectory groups all three generated templates with the source partials and build script that produce them.

**Proposed layout:**

```
neo4j-ee/
├── templates/
│   ├── src/                                     edit these, not the output files
│   │   ├── parameters-common.yaml               ImageId, Password, InstanceType, etc.
│   │   ├── parameters-tls.yaml                  BoltCertificateSecretArn, BoltAdvertisedDNS
│   │   ├── parameters-existing-vpc.yaml         VpcId, SubnetIds, endpoint flags
│   │   ├── conditions.yaml                      Conditions block (template-specific; diverges in Phase 4)
│   │   ├── metadata.yaml                        AWS::CloudFormation::Interface ParameterGroups/Labels
│   │   ├── iam.yaml                             Neo4jRole, Neo4jInstanceProfile, Neo4jBastionRole, Neo4jBastionInstanceProfile
│   │   ├── security-groups.yaml                 Neo4jExternalSecurityGroup, Neo4jInternalSecurityGroup + ingress rules, Neo4jBastionSecurityGroup, VpcEndpointSecurityGroup
│   │   ├── userdata-public.sh                   bootstrap script for Public template (no TLS)
│   │   ├── userdata-private.sh                  bootstrap script for Private template (TLS optional)
│   │   ├── userdata-existing-vpc.sh             bootstrap script for Existing VPC template (TLS optional)
│   │   ├── asg.yaml                             AutoScalingGroups, LaunchTemplate (with # __USERDATA__ placeholder)
│   │   ├── ebs-volumes.yaml                     data volumes with DeletionPolicy: Retain
│   │   ├── stack-config.yaml                    Neo4jPasswordSecret + SSM config params (in-VPC service discovery)
│   │   ├── observability.yaml                   VPC flow logs, app log group, SNS alert topic, CloudWatch alarm, Neo4jFlowLogsIAMRole
│   │   ├── outputs.yaml                         Outputs block (template-specific; diverges in Phase 4)
│   │   ├── networking-public.yaml               VPC + public subnets + IGW + internet NLB
│   │   ├── networking-private.yaml              VPC + public/private subnets + NAT + route tables + VPC endpoints + bastion instance + internal NLB
│   │   └── networking-existing-vpc.yaml         internal NLB + optional VPC endpoints (no VPC creation)
│   ├── build.py                                 assembles src/ partials into output templates
│   ├── neo4j-public.template.yaml               GENERATED — do not edit directly
│   ├── neo4j-private.template.yaml              GENERATED — do not edit directly
│   └── neo4j-private-existing-vpc.template.yaml GENERATED — do not edit directly
│
├── deploy.py                                    updated: --mode selects template file
├── marketplace/                                 unchanged (AMI build is topology-agnostic)
├── validate-private/                            unchanged through Phase 4, then extended
├── sample-private-app/
├── worklog/
└── .deploy/
```

The operational files (`deploy.py`, `teardown.sh`, `test-observability.sh`) stay at the root. The `marketplace/` directory is untouched: the AMI build is topology-agnostic and requires no changes. `validate-private/` stays as-is through Phase 4, then gets extended or renamed in Phase 5.

---

## Partial File Assignments

Every resource in `neo4j.template.yaml` maps to exactly one partial. This table is the authoritative reference for where to place each resource during extraction.

### Parameters

| Partial | Resources |
|---|---|
| `parameters-common.yaml` | ImageId, Password, NumberOfServers, InstanceType, DataDiskSize, DataVolumeKmsKeyId, AlertEmail, DeploymentMode, AllowedCIDR |
| `parameters-tls.yaml` | BoltCertificateSecretArn, BoltAdvertisedDNS |
| `parameters-existing-vpc.yaml` | VpcId, PrivateSubnet1Id, PrivateSubnet2Id, PrivateSubnet3Id, CreateSSMEndpoint, CreateSecretsManagerEndpoint |

### Conditions and Metadata

| Partial | Content | Notes |
|---|---|---|
| `conditions.yaml` | Full `Conditions` block | Template-specific — diverges starting Phase 3; each topology gets its own conditions file. Phase 3 public conditions omit `IsPrivate`/`IsPublic`/`IsPrivateCluster`. Phase 4 private conditions remove them too. |
| `metadata.yaml` | `AWS::CloudFormation::Interface` ParameterGroups and ParameterLabels | Template-specific — diverges starting Phase 3; each topology gets its own metadata file. |

### IAM

| Partial | Resources | Notes |
|---|---|---|
| `iam.yaml` | Neo4jRole, Neo4jInstanceProfile, Neo4jBastionRole, Neo4jBastionInstanceProfile | `Neo4jFlowLogsIAMRole` goes to `observability.yaml`, not here — it is only meaningful alongside the flow log resource |

### Security Groups

| Partial | Resources |
|---|---|
| `security-groups.yaml` | Neo4jExternalSecurityGroup, Neo4jInternalSecurityGroup, Neo4jInternalSGIngress5000/6000/7000/7688/2003/2004/3637, Neo4jBastionSecurityGroup, VpcEndpointSecurityGroup |

### Compute

| Partial | Resources | Notes |
|---|---|---|
| `ebs-volumes.yaml` | Neo4jNode1DataVolume, Neo4jNode2DataVolume, Neo4jNode3DataVolume | |
| `asg.yaml` | Neo4jLaunchTemplate, Neo4jNode1ASG, Neo4jNode2ASG, Neo4jNode3ASG | LaunchTemplate contains a `# __USERDATA__` placeholder where `build.py` injects the preamble + `.sh` body; see UserData Splice below |

### Networking (topology-specific)

| Partial | Resources |
|---|---|
| `networking-private.yaml` | Neo4jVPC, Neo4jSubnet1/2/3, Neo4jPrivateSubnet1/2/3, NAT EIPs, NAT Gateways, private/public route tables and associations, IGW, IGW attachment, Neo4jNetworkLoadBalancer, NLB listeners and target groups, VPC endpoints (ssm, ssmmessages, logs, secretsmanager, s3-gateway), Neo4jOperatorBastion (EC2 instance) |
| `networking-public.yaml` | (Phase 3) VPC, public subnets, IGW, internet-facing NLB |
| `networking-existing-vpc.yaml` | (Phase 5) internal NLB, optional VPC endpoints, bastion |

### Stack Configuration (in-VPC service discovery)

| Partial | Resources | Notes |
|---|---|---|
| `stack-config.yaml` | Neo4jPasswordSecret, Neo4jConfigVpcIdParameter, Neo4jConfigNlbDnsParameter, Neo4jConfigRegionParameter, Neo4jConfigStackNameParameter, Neo4jConfigPrivateSubnet1Parameter, Neo4jConfigPrivateSubnet2Parameter, Neo4jConfigPasswordSecretArnParameter, Neo4jConfigExternalSgIdParameter, Neo4jConfigVpcEndpointSgParameter | Separate from networking because these also appear in the existing-VPC template (Phase 5) — isolating them now makes that reuse clean |

### Observability

| Partial | Resources | Notes |
|---|---|---|
| `observability.yaml` | Neo4jFlowLogsGroup, Neo4jFlowLogsIAMRole, Neo4jVPCFlowLog, Neo4jAppLogGroup, Neo4jAlertTopic, Neo4jFailedAuthMetricFilter, Neo4jFailedAuthAlarm | Identical across all three templates — single partial prevents drift |

### Outputs

| Partial | Content | Notes |
|---|---|---|
| `outputs.yaml` | Full `Outputs` block | Template-specific — diverges starting Phase 3; each topology gets its own outputs file. |

---

## UserData Splice Design

The LaunchTemplate `UserData` block is split between CloudFormation intrinsics (the preamble) and a plain bash script body (the `.sh` files). These cannot live in the same file.

**Approach: `# __USERDATA__` placeholder in `asg.yaml`, replaced by `build.py`.**

`asg.yaml` contains the full LaunchTemplate with `# __USERDATA__` at the correct indentation level where the `UserData:` key belongs. `build.py` generates the complete `UserData: Fn::Base64: !Join [...]` YAML block — including the CF preamble (the `Ref:`/`GetAtt:` variable assignments for `password`, `nodeCount`, `loadBalancerDNSName`, `stackName`, `region`, and for TLS-capable templates `boltCertArn`/`boltAdvertisedDNS`) — then reads the relevant `.sh` file and appends its content as a single string in the join list. The placeholder is then replaced with this rendered block.

This keeps `asg.yaml` as one complete readable file. When adding the public template, `build.py` selects `userdata-public.sh` and omits `boltCertArn`/`boltAdvertisedDNS` from the preamble. No structural change to `asg.yaml` is needed.

---

## On Phase 2: Build System, Not Validation Script

The original framing of Phase 2 as a "validation script" needs adjustment. A script that diffs shared sections across three templates is only useful after three templates exist, and it is a weak control. A developer forgets to run it; the diff accumulates silently.

The stronger answer is the build system itself. If the three templates are generated output from shared source partials, the shared sections cannot drift because there is only one copy. The build script is the enforcement. Phase 2 is about putting that system in place and producing a lint-passing private template from the extracted partials. By the end of Phase 2 the build system is fully functional and CI-enforced; the actual deployment test lives in Phase 4 when the private template is finalised.

---

## Phase 1: Directory Layout and Skeleton ✅

**Goal:** establish the new structure without breaking anything that works today. The existing `neo4j.template.yaml` continues to be the deployable artifact until Phase 2 completes.

- [x] Create `templates/` directory
- [x] Create `templates/src/` directory
- [x] Create `templates/build.py` with a skeleton that reads `src/` and writes output files
- [x] Copy `neo4j.template.yaml` into `templates/src/` as reference material for Phase 2 extraction — do not delete from root yet
- [x] Add a `GENERATED` comment header to the three output template paths in `build.py` so the convention is established from day one
- [x] Decide and record in a `templates/README.md`: output templates go in `templates/`, source partials go in `templates/src/`, edit the partials not the output
- [x] Verify `deploy.py` still works against the root `neo4j.template.yaml` — no changes to `deploy.py` yet

---

## Phase 2: Build System and Continuous Integration ✅

**Goal:** `templates/neo4j-private.template.yaml` is generated from extracted partials, passes cfn-lint, and CI enforces it on every commit. No deployment in this phase. The root `neo4j.template.yaml` remains the live artifact until Phase 4.

Partials are pre-indented YAML fragments (two-space indent, no outer section key). `build.py` concatenates them as text under section headers — no YAML parsing. UserData `.sh` files contain the script body; `build.py` generates the CF preamble (variable assignments via `Ref:`/`GetAtt:` nodes) and injects it via the `# __USERDATA__` placeholder in `asg.yaml`.

The partials do not need to map one-to-one to YAML sections. Extract by concern, not by CloudFormation block. See "Partial File Assignments" above for the authoritative resource-to-partial mapping.

**Extract partials**

- [x] Extract `src/parameters-common.yaml` — ImageId, Password, NumberOfServers, InstanceType, DataDiskSize, DataVolumeKmsKeyId, AlertEmail, DeploymentMode, AllowedCIDR
- [x] Extract `src/parameters-tls.yaml` — BoltCertificateSecretArn, BoltAdvertisedDNS
- [x] Extract `src/conditions.yaml` — full Conditions block as-is (retains `IsPrivate`/`IsPublic`/`IsPrivateCluster`; removed in Phase 4)
- [x] Extract `src/metadata.yaml` — `AWS::CloudFormation::Interface` ParameterGroups and ParameterLabels
- [x] Extract `src/iam.yaml` — Neo4jRole, Neo4jInstanceProfile, Neo4jBastionRole, Neo4jBastionInstanceProfile (not Neo4jFlowLogsIAMRole — that goes to observability.yaml)
- [x] Extract `src/security-groups.yaml` — Neo4jExternalSecurityGroup, Neo4jInternalSecurityGroup, all seven ingress rule resources, Neo4jBastionSecurityGroup, VpcEndpointSecurityGroup
- [x] Extract `src/ebs-volumes.yaml` — Neo4jNode1/2/3DataVolume
- [x] Extract `src/asg.yaml` — Neo4jLaunchTemplate (with `# __USERDATA__` placeholder at the correct indentation level where `UserData:` belongs), Neo4jNode1/2/3ASG
- [x] Extract `src/stack-config.yaml` — Neo4jPasswordSecret and all ten Neo4jConfig* SSM Parameter resources
- [x] Extract `src/observability.yaml` — Neo4jFlowLogsGroup, Neo4jFlowLogsIAMRole, Neo4jVPCFlowLog, Neo4jAppLogGroup, Neo4jAlertTopic, Neo4jFailedAuthMetricFilter, Neo4jFailedAuthAlarm
- [x] Extract `src/outputs.yaml` — full Outputs block as-is
- [x] Extract `src/networking-private.yaml` — all remaining resources (VPC, subnets, NAT, route tables, IGW, NLB, VPC endpoints, Neo4jOperatorBastion EC2 instance); retains `IsPrivate`/`IsPublic`/`IsPrivateCluster` conditions — removed in Phase 4

**Extract UserData scripts**

- [x] Extract `src/userdata-private.sh` — script body starting after the CF preamble variable assignments, including the TLS block
- [x] Create `src/userdata-public.sh` — copy of `userdata-private.sh` with the TLS block removed (the `if [ -n "${boltCertArn}" ]` block in `build_neo4j_conf_file`)
- [x] Create `src/userdata-existing-vpc.sh` — copy of `userdata-private.sh` (identical for now; diverges in Phase 5 if needed)
- [x] Add a diff report to `build.py` that compares the three UserData scripts on every build and prints which sections differ — runs in CI but does not gate the build

**Complete build.py**

- [x] Implement the `# __USERDATA__` splice: `build.py` generates the `UserData: Fn::Base64: !Join [...]` block with the CF preamble (topology-specific: private/existing-vpc preambles include `boltCertArn`/`boltAdvertisedDNS`; public omits them), reads the relevant `.sh` file, appends it as a string, and replaces the placeholder in the rendered `asg.yaml` content
- [x] Implement text-stitching assembly for `neo4j-private.template.yaml`: emit section headers (`AWSTemplateFormatVersion`, `Description`, `Metadata:`, `Parameters:`, `Conditions:`, `Resources:`, `Outputs:`) and concatenate the relevant partials under each; public and existing-VPC outputs remain placeholder stubs
- [x] Add `--verify` flag: when passed, diff the generated `neo4j-private.template.yaml` against the committed file and exit non-zero if they differ; use this in CI to enforce that committed output is always up to date

**Validate and enforce**

- [x] Run `cfn-lint templates/neo4j-private.template.yaml` and confirm it passes
- [x] Create `.pre-commit-config.yaml` at the repo root with a hook that runs `python templates/build.py --verify` and fails if the generated output differs from what is committed
- [x] Create `.github/workflows/validate-templates.yml` with a CI job that runs `python templates/build.py --verify` and `cfn-lint templates/neo4j-private.template.yaml` on every pull request

---

## Execution Model for Phases 3–5

Phases 3 and 4 can run in parallel — every topology-specific file is separate (`networking-public.yaml`, `conditions-public.yaml`, `outputs-public.yaml` vs. `networking-private.yaml`), and neither phase touches a shared source partial that the other modifies. The only shared file is `build.py`: Phase 3 adds `_assemble_public()` and Phase 4 modifies `_assemble_private()`. These are distinct functions; the only merge conflict is additive lines in `_build()` and `_verify()`.

Phase 5 must wait for Phase 4 to merge. `src/stack-config.yaml` gates all ten of its resources on `IsPrivate` or `IsPrivateCluster`. Phase 4 must replace those with unconditional or `CreateCluster` conditions. Phase 5 then inherits that cleaned-up partial — its first task explicitly revisits those condition names. Two agents modifying `stack-config.yaml` in parallel would produce a non-trivial merge conflict.

```
Phase 3 (Public)  ──────────────────────────────────────► merge
Phase 4 (Private) ──────────────────────────────────────► merge ──► Phase 5 (Existing VPC)
```

---

## Phase 3: Public Template

**Goal:** `templates/neo4j-public.template.yaml` is generated, deployed, and validated.

What changes from the current template:
- No private subnets, no NAT gateways, no bastion, no VPC endpoints
- Internet-facing NLB instead of internal
- TLS parameters removed (`BoltCertificateSecretArn`, `BoltAdvertisedDNS`)
- `AllowedCIDR` has no default that opens public internet access (current validation pattern already rejects `0.0.0.0/0`)
- `NumberOfServers` stays: 1 or 3, default 3

- [ ] Create `src/conditions-public.yaml` — `CreateCluster` and `HasAlertEmail` only; no `IsPrivate`/`IsPublic`/`IsPrivateCluster`
- [ ] Create `src/metadata-public.yaml` — `AWS::CloudFormation::Interface` ParameterGroups without TLS parameters
- [ ] Create `src/outputs-public.yaml` — `Neo4jBrowserURL`, `Neo4jURI`, plus common outputs (Username, log groups, alarm); no SSM commands, bastion ID, or password ARN
- [ ] Create `src/networking-public.yaml`: VPC, public subnets, internet gateway, internet-facing NLB
- [ ] Implement `_assemble_public()` in `build.py` that uses `parameters-common.yaml` (no TLS params) + `conditions-public.yaml` + `metadata-public.yaml` + `iam.yaml` + `security-groups.yaml` + `ebs-volumes.yaml` + `asg.yaml` (with `userdata-public.sh`, preamble omits `boltCertArn`/`boltAdvertisedDNS`) + `networking-public.yaml` + `observability.yaml` + `outputs-public.yaml`
- [ ] Confirm TLS parameters are absent from the generated Public template
- [ ] cfn-lint passes on `neo4j-public.template.yaml`
- [ ] Update CI workflow to lint `neo4j-public.template.yaml`
- [ ] Deploy test: 1-node public, confirm HTTP (7474) and Bolt (7687) reachable
- [ ] Deploy test: 3-node public cluster, confirm all three nodes join and cluster forms
- [ ] Teardown both test stacks cleanly
- [ ] Update `deploy.py`: `--mode public` selects `templates/neo4j-public.template.yaml`
- [ ] Create architectural diagram for Public template (1100x700 pixels, current AWS icons, shows VPC + public subnets + internet-facing NLB + EC2 nodes)
- [ ] Update `README.md` to reference the new template name

---

## Phase 4: Private Template

**Goal:** `templates/neo4j-private.template.yaml` is generated, deployed, and validated.

What changes from the current template:
- NAT gateways, private subnets, VPC endpoints, bastion all stay exactly as today
- Internal NLB
- TLS parameters included as optional (`BoltCertificateSecretArn`, `BoltAdvertisedDNS`)
- `AllowedCIDR` defaults to `10.0.0.0/16` (the VPC CIDR the template creates)
- `NumberOfServers`: 1 or 3, default 3

This template is the closest to the current Private mode. The main work is removing the `IsPublic`/`IsPrivate` conditional branching — the networking section is now unconditionally private.

- [ ] Rewrite `src/networking-private.yaml` to be unconditionally private: remove all `IsPrivate`, `IsPublic`, `IsPrivateCluster` conditions; replace conditional resource blocks with the private-mode resources directly (public subnets for NAT only, private subnets for instances, NAT gateways, route tables, VPC endpoints, bastion, internal NLB)
- [ ] Update `build.py` to assemble Private template from `parameters-common.yaml` + `parameters-tls.yaml` + `conditions.yaml` (now unconditional private — `IsPrivate`/`IsPublic` removed) + `metadata.yaml` + `iam.yaml` + `security-groups.yaml` + `ebs-volumes.yaml` + `asg.yaml` (with `userdata-private.sh`) + `networking-private.yaml` + `stack-config.yaml` + `observability.yaml` + `outputs.yaml`
- [ ] Confirm all `IsPrivate`, `IsPublic`, `IsPrivateCluster` conditions are absent from the generated output — the template should have no conditional branching on deployment mode
- [ ] cfn-lint passes on `neo4j-private.template.yaml`
- [ ] Deploy test: 1-node private, confirm SSM Session Manager access to bastion, confirm Bolt reachable from within VPC
- [ ] Deploy test: 3-node private cluster, confirm cluster forms and Raft converges
- [ ] Deploy test: 3-node private with TLS, confirm Bolt TLS handshake succeeds
- [ ] Run `validate-private/` tooling against the deployed 3-node stack
- [ ] Teardown all test stacks cleanly
- [ ] Delete `neo4j.template.yaml` from the root — `templates/neo4j-private.template.yaml` is now the deployable Private artifact
- [ ] Update `deploy.py`: `--mode private` selects `templates/neo4j-private.template.yaml` (make `private` the default mode)
- [ ] Rename `validate-private/` to `validate/` and update its README to reflect that it validates the Private template
- [ ] Create architectural diagram for Private template (1100x700 pixels, shows VPC + public/private subnets + NAT gateways + bastion + internal NLB + EC2 nodes in private subnets)
- [ ] Update `README.md`

---

## Phase 5: Private, Existing VPC Template

**Depends on Phase 4 merge.** `src/stack-config.yaml` must have its `IsPrivate`/`IsPrivateCluster` conditions replaced (Phase 4 work) before this phase begins.

**Goal:** `templates/neo4j-private-existing-vpc.template.yaml` is generated, deployed into a pre-existing VPC, and validated.

What is new in this template vs. Private:
- No VPC, subnets, IGW, NAT gateways, or route tables created
- New parameters: `VpcId`, `PrivateSubnet1Id`, `PrivateSubnet2Id`, `PrivateSubnet3Id`
- New parameters: `CreateSSMEndpoint` (boolean, default true) and `CreateSecretsManagerEndpoint` (boolean, default true) — set false if the buyer's VPC already has those endpoints
- `AllowedCIDR`: no default — buyer must enter their VPC CIDR explicitly; description says "enter the CIDR of your existing VPC, for example 10.0.0.0/16 or 172.16.0.0/12"
- Bastion: created and documented — template description explains the bastion is a purpose-built SSM access point with no ingress rules, and that it will be provisioned in the buyer's VPC
- TLS parameters: included as optional
- `NumberOfServers`: 1 or 3, default 3; 3-node deployment requires three subnet IDs in separate availability zones

- [ ] Revisit `Condition:` names in `stack-config.yaml` — all resources are currently gated on `IsPrivate`/`IsPrivateCluster`, which won't exist in a single-topology template; replace with topology-appropriate conditions (e.g., `CreateCluster` for the per-node subnet params)
- [ ] Create `src/parameters-existing-vpc.yaml`: `VpcId`, three subnet ID parameters, `CreateSSMEndpoint`, `CreateSecretsManagerEndpoint`
- [ ] Create `src/networking-existing-vpc.yaml`: bastion instance, optional VPC endpoints (conditional on the two flags), internal NLB using buyer-provided subnets — no VPC or subnet resources created
- [ ] Update `build.py` to assemble Existing VPC template from common params + TLS params + existing-vpc params + existing-vpc networking + shared cluster resources
- [ ] Confirm no VPC, subnet, IGW, NAT, or route table resources appear in the generated output
- [ ] Add template description text explaining the bastion, what it does, and why it is created
- [ ] cfn-lint passes on `neo4j-private-existing-vpc.template.yaml`
- [ ] Deploy test: create a fresh VPC with private subnets and NAT gateway out-of-band (simulates a buyer's existing VPC), then deploy the Existing VPC template into it — 1-node
- [ ] Deploy test: 3-node into the same pre-existing VPC, confirm cluster forms
- [ ] Deploy test: `CreateSSMEndpoint=false` using a VPC that already has an SSM endpoint, confirm no duplicate resource error
- [ ] Deploy test: with TLS
- [ ] Validate connectivity and cluster health
- [ ] Teardown all test stacks and the pre-existing VPC cleanly
- [ ] Update `deploy.py`: `--mode existing-vpc` selects `templates/neo4j-private-existing-vpc.template.yaml`; document that `--allowed-cidr` is required for this mode
- [ ] Extend `validate/` tooling to cover the Existing VPC topology
- [ ] Create architectural diagram for Existing VPC template (1100x700 pixels, shows pre-existing VPC with buyer-provided subnets + bastion + internal NLB + EC2 nodes — no VPC creation shown)
- [ ] Update `README.md`

---

## After Phase 5: Marketplace Submission

These steps are outside the scope of the split work but follow directly from it.

- [ ] Confirm all three generated templates pass Marketplace's AMI parameter injection (AWS Marketplace replaces the `ImageId` SSM parameter path with its own)
- [ ] Verify parameter group metadata (`AWS::CloudFormation::Interface`) presents cleanly in the CloudFormation console for each template
- [ ] Submit all three templates and diagrams to the Marketplace seller portal
- [ ] Run a smoke test through the Marketplace launch flow for each template to confirm the buyer experience
- [ ] Update the product description in the seller portal to explain the three templates and their target buyers
