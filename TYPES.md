# EC2 Instance Type Recommendations for Neo4j Marketplace Listings

## Does Neo4j Require Intel Only?

**No.** The [Neo4j Operations Manual](https://neo4j.com/docs/operations-manual/current/installation/requirements/)
states:

> Neo4j is supported on systems with x86_64 and ARM architectures on physical, virtual, or
> containerized platforms.

Both Intel and AMD processors are fully supported under x86_64. Neo4j Aura itself runs
predominantly on AMD instances (m6a, c6a, r6a families) across 3,000+ instances in AWS
(see HW.md for details). ARM (e.g., Graviton) is also supported by the Neo4j runtime,
though Aura has not yet migrated its toolchain to ARM.

The claim that "Neo4j only supports Intel" is **not accurate**.

## Current State

### Enterprise Edition (EE) — Marketplace Live

The EE CloudFormation template (`neo4j-ee/neo4j.template.yaml`) and the live marketplace
listing use r8i (Intel Gen 8, memory-optimized) exclusively:

| Instance | vCPU | Memory (GiB) | Tier |
|-----------|------|-------------|------|
| t3.medium | 2 | 4 | Dev / testing |
| r8i.large | 2 | 16 | Entry production |
| r8i.xlarge | 4 | 32 | Small production (default) |
| r8i.2xlarge | 8 | 64 | Medium production |
| r8i.4xlarge | 16 | 128 | Large production |
| r8i.8xlarge | 32 | 256 | Large production |
| r8i.12xlarge | 48 | 384 | XL production |
| r8i.16xlarge | 64 | 512 | XL production |
| r8i.24xlarge | 96 | 768 | XXL production |
| r8i.32xlarge | 128 | 1024 | XXL production |
| r8i.48xlarge | 192 | 1536 | Max production |
| r8i.96xlarge | 384 | 3072 | Max production |

**Default:** r8i.xlarge (4 vCPU / 32 GB)

### Community Edition (CE) — Template (Not Yet Listed)

The CE CloudFormation template (`neo4j-ce/neo4j.template.yaml`) uses r8i + t3,
aligned with the EE listing:

| Instance | vCPU | Memory (GiB) | Family |
|-----------|------|-------------|--------|
| t3.medium | 2 | 4 | Burstable |
| t3.large | 2 | 8 | Burstable |
| r8i.large | 2 | 16 | Memory opt (Intel Gen 8) |
| r8i.xlarge | 4 | 32 | Memory opt (Intel Gen 8) |
| r8i.2xlarge | 8 | 64 | Memory opt (Intel Gen 8) |
| r8i.4xlarge | 16 | 128 | Memory opt (Intel Gen 8) |
| r8i.8xlarge | 32 | 256 | Memory opt (Intel Gen 8) |

**Default:** t3.medium (2 vCPU / 4 GB)

## Analysis: Why EE Uses r8i

The EE listing chose r8i for practical marketplace reasons, not because Neo4j requires Intel:

1. **Single family simplicity** — One memory-optimized family (r8i) covers all production
   sizes from 16 GB to 3 TB. Customers pick a size, not a family.
2. **Marketplace listing constraints** — AWS Marketplace listings define a fixed set of
   supported instance types at AMI registration time. Fewer families = simpler listing.
3. **r8i availability** — r8i (Intel Xeon 6) is broadly available across AWS regions.
   r8a (AMD EPYC Turin) was only launched Nov 2025 and is currently limited to 3 US
   regions (us-east-1, us-east-2, us-west-2).
4. **Generation alignment** — r8i is current-gen (Gen 8). The CE template now also uses
   r8i, aligned with EE.

## Recommendation: Align CE with EE

To keep a small, consistent list across both marketplace listings, align CE with the EE
approach — use **r8i + t3** as the standard families.

### Proposed CE Instance Types

The marketplace listing is currently configured with 14 instance types (same as EE).
Below is the full list with recommendations for which to keep or drop.

| Instance | vCPU | Memory (GiB) | Use Case | Recommendation |
|-----------|------|-------------|----------|----------------|
| t3.medium | 2 | 4 | Dev / learning | **Keep** — default for CE |
| t3.large | 2 | 8 | Dev / learning | **Keep** — slightly larger dev |
| t3.xlarge | 4 | 16 | Dev / learning | **Drop** — r8i.large is better value (16 GB mem-optimized vs 16 GB burstable) |
| r8i.large | 2 | 16 | Small production | **Keep** — entry production |
| r8i.xlarge | 4 | 32 | Medium production | **Keep** — solid mid-tier |
| r8i.2xlarge | 8 | 64 | Large production | **Keep** — large workloads |
| r8i.4xlarge | 16 | 128 | XL production | **Keep** — heavy workloads |
| r8i.8xlarge | 32 | 256 | Max CE production | **Keep** — cap for CE (no clustering) |
| r8i.12xlarge | 48 | 384 | — | **Drop** — beyond single-node CE needs; use EE |
| r8i.16xlarge | 64 | 512 | — | **Drop** — beyond single-node CE needs; use EE |
| r8i.24xlarge | 96 | 768 | — | **Drop** — beyond single-node CE needs; use EE |
| r8i.32xlarge | 128 | 1024 | — | **Drop** — beyond single-node CE needs; use EE |
| r8i.48xlarge | 192 | 1536 | — | **Drop** — beyond single-node CE needs; use EE |
| r8i.96xlarge | 384 | 3072 | — | **Drop** — beyond single-node CE needs; use EE |

**Result:** 8 types kept, 6 dropped.

**Default:** t3.medium (Community Edition is commonly used for dev/learning)

### Rationale

- **8 instance types** — small, manageable list for marketplace registration.
- **Caps at r8i.8xlarge** — Community Edition does not support clustering; workloads
  beyond 256 GB RAM should be on Enterprise Edition.
- **Drops m6a and r6a** — eliminates Gen 6 AMD, aligns with the r8i-based EE listing.
  When r8a becomes broadly available, both listings could add AMD options.
- **Keeps t3 for dev** — t3 is ubiquitous, cheap, and appropriate for non-production.
  Burstable instances for dev/testing is a pattern customers expect.
- **Drops t3.xlarge** — at that price point, r8i.large offers better memory-to-cost
  ratio for graph workloads (16 GB memory-optimized vs 16 GB burstable).

## Future Consideration: r8a (AMD Gen 8)

Once r8a instances reach broad regional availability (currently only 3 regions), adding
them would provide a cost-effective AMD alternative:

- r8a delivers up to 30% better performance vs r7a and better price-performance than r8i.
- AMD instances historically cost ~10% less than equivalent Intel instances.
- Neo4j Aura's production fleet is heavily AMD-based, confirming compatibility.

Adding r8a should be considered when it reaches GA in 10+ regions.

## Summary

| Question | Answer |
|----------|--------|
| Does Neo4j require Intel? | No. x86_64 (Intel + AMD) and ARM are all supported. |
| Why does EE use r8i? | Broad availability, current gen, single-family simplicity. |
| Should CE match EE? | Yes — align on r8i + t3 for consistency. |
| Should we add r8a? | Not yet — only 3 US regions as of Feb 2026. |
| What about Graviton/ARM? | Supported by Neo4j but not used in Aura yet; defer. |

## References

- [Neo4j System Requirements](https://neo4j.com/docs/operations-manual/current/installation/requirements/)
- [Neo4j on AWS](https://neo4j.com/docs/operations-manual/current/cloud-deployments/neo4j-aws/)
- [AWS EC2 R8i Instances](https://aws.amazon.com/ec2/instance-types/r8i/)
- [AWS EC2 R8a Instances](https://aws.amazon.com/ec2/instance-types/r8a/)
- [Neo4j EE AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4)
- Internal: HW.md (Aura Infrastructure Lessons Learnt)
