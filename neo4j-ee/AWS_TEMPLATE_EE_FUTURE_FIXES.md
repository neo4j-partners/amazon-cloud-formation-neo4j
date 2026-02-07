# Neo4j Enterprise Edition -- AWS Template Future Fixes

Recommended improvements for `neo4j-ee/neo4j.template.yaml` based on the
[Neo4j Operations Manual](https://neo4j.com/docs/operations-manual/current/),
AWS best practices, and internal Aura infrastructure lessons (HW.md).

---

## 1. Separate EBS Data Volume That Survives Instance Replacement

**Problem:** The template uses a single root EBS volume (`/dev/xvda`). When the
ASG replaces an instance the old root volume is destroyed and all Neo4j data is
lost. The Operations Manual explicitly warns that ASG-managed Neo4j servers must
remount their original EBS volume or they will "start with no data or fail to
rejoin the cluster."

**Fix:**
- Create a dedicated EBS volume per cluster member, tagged with a stable server
  identity.
- In UserData, locate the tagged volume via `aws ec2 describe-volumes`, attach
  it, and mount it at `/var/lib/neo4j/data`.
- Use rolling updates only (`maxSurge=0`, `maxUnavailable=1`) so a replacement
  instance can pick up the volume released by the terminated one.

**Docs:**
- [Neo4j on AWS -- Operations Manual](https://neo4j.com/docs/operations-manual/current/cloud-deployments/neo4j-aws/)
- [Disks, RAM and other tips](https://neo4j.com/docs/operations-manual/current/performance/disks-ram-and-other-tips/)

---

## 2. Separate Volumes for Data and Transaction Logs

**Problem:** All data, transaction logs, and application logs share the root EBS
volume. The Operations Manual states: "Store database and transaction logs on
separate physical devices to optimize for Neo4j's characteristic access
patterns -- many small random reads during queries and few sequential writes
during commits."

**Fix:**
- Provision at least two dedicated EBS volumes per instance:
  - **Volume 1 (Data):** random reads -- mount at `/data`, set
    `server.directories.data=/data`
  - **Volume 2 (Transaction logs):** sequential writes -- mount at
    `/txlogs`, set
    `server.directories.transaction.logs.root=/txlogs`
- Optionally a third volume for application logs
  (`server.directories.logs`).

**Docs:**
- [Linux file system tuning](https://neo4j.com/docs/operations-manual/current/performance/linux-file-system-tuning/)
- [Transaction logging](https://neo4j.com/docs/operations-manual/current/database-internals/transaction-logs/)
- [Default file locations](https://neo4j.com/docs/operations-manual/current/configuration/file-locations/)

---

## 3. File System Mount Options

**Problem:** The template does not configure mount options. The Operations Manual
recommends `noatime,nodiratime` to eliminate unnecessary metadata writes, and
EXT4 as the preferred file system.

**Fix:**
- Format EBS volumes as EXT4.
- Mount with `noatime,nodiratime`.
- Never use NFS or NAS -- Neo4j requires a POSIX-compliant local file system.

**Docs:**
- [Linux file system tuning](https://neo4j.com/docs/operations-manual/current/performance/linux-file-system-tuning/)

---

## 4. SSD Over-Provisioning

**Problem:** `DiskSize` defaults to 100 GB with `MinValue: 100`. The Operations
Manual recommends over-provisioning SSDs by at least 20 % to combat wear under
sustained write loads.

**Fix:**
- Document the 20 % guidance in the parameter description.
- Consider raising `MinValue` or adding a note that the user-specified size
  should be at least 20 % larger than the expected data footprint.

**Docs:**
- [Disks, RAM and other tips](https://neo4j.com/docs/operations-manual/current/performance/disks-ram-and-other-tips/)

---

## 5. Backup Configuration

**Problem:** The template does not configure any backup mechanism. A full cluster
loss (unlikely but possible) destroys all data.

**Fix -- option A (Enterprise online backup to S3):**
- Enable the backup listener: `server.backup.enabled=true` and
  `server.backup.listen_address=127.0.0.1:6362`
- Schedule `neo4j-admin database backup --to-path=s3://<bucket>/` via cron
  or a sidecar.
- Back up the `system` database, config files, certs, and plugins alongside
  user databases.

**Fix -- option B (EBS snapshots):**
- Create a Lambda or EventBridge-triggered snapshot schedule for data volumes.
- Snapshots persist to S3 automatically and can be restored across AZs.

**Docs:**
- [Backup and restore planning](https://neo4j.com/docs/operations-manual/current/backup-restore/planning/)
- [Back up an online database](https://neo4j.com/docs/operations-manual/current/backup-restore/online-backup/)

---

## 6. File Descriptor Limits

**Problem:** The default Linux limit of 1024 open file descriptors is
insufficient for Neo4j. The Operations Manual recommends 40,000--60,000.

**Fix:**
- Add to UserData:
  ```bash
  echo "neo4j soft nofile 60000" >> /etc/security/limits.conf
  echo "neo4j hard nofile 60000" >> /etc/security/limits.conf
  ```
- Or set `LimitNOFILE=60000` in the systemd unit override.

**Docs:**
- [Linux installation](https://neo4j.com/docs/operations-manual/current/installation/linux/)

---

## 7. Swap Disabled

**Problem:** Swap is not disabled. The Operations Manual warns that paging to
disk severely degrades Neo4j performance and recommends disabling swap on
production servers.

**Fix:**
- Add `swapoff -a` and remove swap entries from `/etc/fstab` in UserData.

**Docs:**
- [Memory configuration](https://neo4j.com/docs/operations-manual/current/performance/memory-configuration/)

---

## 8. Add Gen 6 AMD Instance Families (m6a, c6a, r6a)

**Problem:** The template offers only `r8i` (Intel gen 8) and `t3.medium`.
HW.md reports that Aura runs 3,112 instances on AWS and the overwhelming
majority are gen 6 AMD. HW.md also warns: "Generation 7 and 8 are not widely
enough available to be the general recommendation."

The current instance list creates two risks:
- **Availability:** `r8i` may not be available in all regions / AZs.
- **Missing families:** Aura's second-largest fleet segment is `c6a`
  (compute-optimized, 1,179 instances), which is not offered at all.

**Fix:**
- Add `m6a` (general purpose), `c6a` (compute-optimized), and `r6a`
  (memory-optimized) families as the primary gen 6 AMD tier.
- Keep `r8i` for users who want the latest generation.
- Consider changing the default from `r8i.xlarge` to `m6a.xlarge` or
  `r6a.xlarge` for broader availability.

**Proposed additions:**
```yaml
# General purpose (AMD gen 6) — Aura's largest fleet segment
- m6a.large        # 2 vCPU,   8 GB
- m6a.xlarge       # 4 vCPU,  16 GB
- m6a.2xlarge      # 8 vCPU,  32 GB
- m6a.4xlarge      # 16 vCPU,  64 GB
# Compute optimized (AMD gen 6) — query-heavy, dataset fits in memory
- c6a.large        # 2 vCPU,   4 GB
- c6a.xlarge       # 4 vCPU,   8 GB
- c6a.2xlarge      # 8 vCPU,  16 GB
- c6a.4xlarge      # 16 vCPU,  32 GB
# Memory optimized (AMD gen 6) — large graph production workloads
- r6a.large        # 2 vCPU,  16 GB
- r6a.xlarge       # 4 vCPU,  32 GB
- r6a.2xlarge      # 8 vCPU,  64 GB
- r6a.4xlarge      # 16 vCPU, 128 GB
```

**Source:** HW.md -- Aura AWS instance usage data; gen 7/8 availability warning.

---

## 9. Minimum Memory Guidance

**Problem:** `t3.medium` (4 GB RAM) is offered as a valid choice with no
guidance. HW.md states 1-2 GB sizes "should not be recommended" and
"recommending 4GB and up is a good idea." For Enterprise with clustering, the
minimum should be higher.

**Fix:**
- Update the `InstanceType` description to state that `t3.medium` is for
  development only and 16 GB+ is recommended for production clusters.

**Source:** HW.md -- Aura minimum sizing guidance.

---

## 10. Graviton / ARM Instance Types

**Problem:** The template only offers Intel/AMD instance types. AWS Graviton3
instances deliver 13--146 % performance improvement with 15 % cost savings for
Neo4j workloads. HW.md confirms: "Neo4j itself has been benchmarked and tested
on ARM and runs really well on it."

**Fix:**
- Add `r7g` (Graviton3) and `r8g` (Graviton4) instance types to
  `AllowedValues`. The Neo4j AMI must be built for `arm64`.

**Docs:**
- [Give Your Graph Workload a Cost-Performance Boost with Neo4j and AWS Graviton (AWS Blog)](https://aws.amazon.com/blogs/apn/give-your-graph-workload-a-cost-performance-boost-with-neo4j-and-aws-graviton/)

**Source:** HW.md -- ARM/Graviton benchmarking confirmation.

---

## 11. EBS gp3 IOPS and Throughput Provisioning

**Problem:** Both data and transaction log volumes use gp3 at baseline (3,000
IOPS / 125 MiB/s) with no way to provision higher values. HW.md highlights
that EBS gp3 requires careful tuning of IOPS, throughput, and size together:
"Understanding how to best scale storage and how these relate to each other as
we scale is hard and time consuming."

A common pitfall: provisioning high IOPS but leaving throughput at 125 MiB/s
creates a bottleneck on sequential writes (transaction log commits,
checkpoints).

HW.md also confirms io2 is "ridiculously expensive" and Aura avoids it, so
gp3 with tuned IOPS/throughput is the right approach.

**Fix:**
- Add optional parameters `DataVolumeIops` (default 3000, max 16000) and
  `DataVolumeThroughput` (default 125, max 1000).
- Apply the same to the transaction log volume.
- Document that IOPS and throughput should be scaled together.

**Source:** HW.md -- EBS complexity discussion; io2 cost avoidance.

---

## 12. Checkpoint and Transaction Log Tuning

**Problem:** The template does not set `db.checkpoint.iops.limit` or transaction
log retention. The defaults (600 IOPS / `2 days 2G`) may not suit all
workloads.

**Fix:**
- Expose `db.checkpoint.iops.limit` as a parameter or document the trade-off
  (lower limit = less I/O contention but longer checkpoints).
- For deployments using differential backup, consider increasing
  `db.tx_log.rotation.retention_policy` beyond the default.

**Docs:**
- [Checkpointing and log pruning](https://neo4j.com/docs/operations-manual/current/database-internals/checkpointing/)
- [Transaction logging](https://neo4j.com/docs/operations-manual/current/database-internals/transaction-logs/)

---

## 13. Cypher IP Blocklist for IPv4 CIDR Completeness

**Problem:** The blocklist omits `100.64.0.0/10` (carrier-grade NAT range used
by some AWS VPC configurations).

**Fix:**
- Append `100.64.0.0/10` to `internal.dbms.cypher_ip_blocklist`.

---

## 14. IMDSv2 Enforcement

**Problem:** The launch template does not set `MetadataOptions`. The CE template
already enforces IMDSv2 (`HttpTokens: required`). EE should match.

**Fix:**
```yaml
MetadataOptions:
  HttpTokens: required
  HttpEndpoint: enabled
```

---

## 15. CloudFormation Signal for Deployment Validation

**Problem:** The EE template does not use `CreationPolicy` /
`cfn-signal`. There is no way for CloudFormation to know whether Neo4j
actually started successfully. The CE template already implements this.

**Fix:**
- Add `CreationPolicy.ResourceSignal` to the ASG.
- Grant `cloudformation:SignalResource` in the IAM policy.
- Call `aws cloudformation signal-resource` at the end of UserData on
  success, and trap errors to signal `FAILURE`.

**Docs:**
- [AWS CloudFormation CreationPolicy](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-creationpolicy.html)

---

## 16. Neo4j Installation from AMI Instead of Yum

**Problem:** The EE template installs Neo4j at boot via `yum install`, which
adds cold-start latency and depends on external repositories being reachable.
The CE template uses a pre-baked AMI.

**Fix:**
- Bake Neo4j into the AMI (as CE does) so startup only requires
  configuration, not installation.
- This eliminates the external dependency on `yum.neo4j.com` and reduces
  boot time.

---

## Priority Order

| Priority | Item | Rationale |
|----------|------|-----------|
| P0 | 1 -- Persistent EBS volumes | Data loss on instance replacement |
| P0 | 5 -- Backup configuration | No recovery path for total loss |
| P0 | 15 -- cfn-signal | Deployment succeeds silently even if Neo4j fails |
| P0 | 14 -- IMDSv2 | Security baseline |
| P0 | 8 -- Gen 6 AMD instance families | r8i availability risk; Aura fleet alignment |
| P1 | 2 -- Separate data/txlog volumes | Performance per Operations Manual |
| P1 | 16 -- AMI-based install | Reliability and boot speed |
| P1 | 6 -- File descriptors | Stability under load |
| P1 | 7 -- Swap disabled | Performance under load |
| P1 | 11 -- gp3 IOPS/throughput provisioning | Production I/O performance |
| P2 | 3 -- Mount options | Incremental performance |
| P2 | 4 -- SSD over-provisioning | Longevity |
| P2 | 10 -- Graviton instances | Cost-performance (requires ARM AMI) |
| P2 | 9 -- Minimum memory guidance | User documentation |
| P2 | 12 -- Checkpoint tuning | Workload-dependent |
| P3 | 13 -- IPv4 blocklist gap | Edge case |
