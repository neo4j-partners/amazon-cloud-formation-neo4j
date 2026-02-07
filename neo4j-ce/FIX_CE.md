# Neo4j Community Edition -- Recommendations and Fix Plan

Issues and implementation plan for `neo4j-ce/neo4j.template.yaml` based on the
[Neo4j Operations Manual](https://neo4j.com/docs/operations-manual/current/),
AWS best practices, and internal Aura infrastructure lessons (HW.md).

---

## Recommendations

### R1. Add a Separate EBS Data Volume

**Current state:** All Neo4j data lives on the root EBS volume (`/dev/xvda`).
When the ASG replaces the instance the root volume is destroyed and all data is
lost.

**Target state:** A dedicated EBS volume is created as a standalone
`AWS::EC2::Volume` resource, attached and mounted in UserData, and formatted on
first use. Because the volume is a separate CloudFormation resource it is
**not** destroyed when the ASG replaces an instance.

**Docs:**
- [Neo4j on AWS](https://neo4j.com/docs/operations-manual/current/cloud-deployments/neo4j-aws/)
- [Disks, RAM and other tips](https://neo4j.com/docs/operations-manual/current/performance/disks-ram-and-other-tips/)

### R2. Separate Transaction Logs Onto Their Own Volume

**Current state:** Data store files and transaction logs share the same device.

**Target state:** A second dedicated EBS volume is mounted for transaction logs.
`server.directories.transaction.logs.root` is set to the mount point.

The Operations Manual states: "Store database and transaction logs on separate
physical devices to optimize for Neo4j's characteristic access patterns -- many
small random reads during queries and few sequential writes during commits."

**Docs:**
- [Linux file system tuning](https://neo4j.com/docs/operations-manual/current/performance/linux-file-system-tuning/)
- [Transaction logging](https://neo4j.com/docs/operations-manual/current/database-internals/transaction-logs/)
- [Default file locations](https://neo4j.com/docs/operations-manual/current/configuration/file-locations/)

### R3. EXT4 with noatime,nodiratime

**Current state:** Volume is formatted with the AMI default; no mount options
specified.

**Target state:** Data and txlog volumes formatted as EXT4 and mounted with
`noatime,nodiratime`.

**Docs:**
- [Linux file system tuning](https://neo4j.com/docs/operations-manual/current/performance/linux-file-system-tuning/)

### R4. SSD Over-Provisioning Guidance

**Current state:** `DiskSize` defaults to 30 GB with `MinValue: 10`.

**Target state:** Raise `MinValue` to 20. Add guidance in the parameter
description that the value should be at least 20 % larger than the expected data
footprint.

**Docs:**
- [Disks, RAM and other tips](https://neo4j.com/docs/operations-manual/current/performance/disks-ram-and-other-tips/)

### R5. File Descriptor Limits

**Current state:** Not configured. Linux default is 1024.

**Target state:** Set `LimitNOFILE=60000` in the neo4j systemd override.

**Docs:**
- [Linux installation](https://neo4j.com/docs/operations-manual/current/installation/linux/)

### R6. Disable Swap

**Current state:** Swap is not disabled.

**Target state:** `swapoff -a` in UserData and swap entries removed from
`/etc/fstab`.

**Docs:**
- [Memory configuration](https://neo4j.com/docs/operations-manual/current/performance/memory-configuration/)

### R7. Backup to S3

**Current state:** No backup mechanism.

**Target state:** Add an optional cron-based dump to S3 using
`neo4j-admin database dump --to-path=s3://<bucket>/`. CE does not support
online backup, so the dump requires a brief stop or can be run against
a snapshot of the data volume.

Alternatively, configure EBS snapshot scheduling via AWS Data Lifecycle
Manager or an EventBridge rule.

**Docs:**
- [Back up an offline database](https://neo4j.com/docs/operations-manual/current/backup-restore/offline-backup/)
- [Backup and restore planning](https://neo4j.com/docs/operations-manual/current/backup-restore/planning/)

### R8. Add Compute-Optimized (c6a) Instance Types

**Current state:** The template offers burstable (t3), general purpose (m6a),
and memory-optimized (r6a) instances but no compute-optimized types.

**Target state:** Add `c6a` (compute-optimized, AMD gen 6) instance types.
Aura's second-largest fleet segment on AWS is c6a with 1,179 instances.
Compute-optimized is relevant for query-heavy workloads where the dataset fits
in memory.

**Proposed additions:**
```
- c6a.large        # 2 vCPU,   4 GB
- c6a.xlarge       # 4 vCPU,   8 GB
- c6a.2xlarge      # 8 vCPU,  16 GB
```

**Source:** HW.md -- Aura AWS instance usage data.

### R9. Minimum Memory Guidance

**Current state:** The default `t3.medium` (4 GB RAM) is offered without
guidance. HW.md states 1-2 GB sizes "should not be recommended" and
"recommending 4GB and up is a good idea."

**Target state:** Add a note in the `InstanceType` parameter description that
`t3.medium` (4 GB) is the minimum for development use and 8 GB+ is recommended
for real workloads.

**Source:** HW.md -- Aura minimum sizing guidance.

### R10. Graviton Instance Types

**Current state:** Only Intel/AMD types offered (t3, m6a, r6a).

**Target state:** Add Graviton equivalents (t4g, m7g, r7g) for 15 % cost
savings and up to 146 % performance improvement. HW.md confirms "Neo4j itself
has been benchmarked and tested on ARM and runs really well on it."

**Docs:**
- [Give Your Graph Workload a Cost-Performance Boost with Neo4j and AWS Graviton](https://aws.amazon.com/blogs/apn/give-your-graph-workload-a-cost-performance-boost-with-neo4j-and-aws-graviton/)

**Source:** HW.md -- ARM/Graviton benchmarking confirmation.

### R11. Checkpoint IOPS Tuning

**Current state:** Not configured (default 600 IOPS = ~5 MiB/s).

**Target state:** Document the setting and optionally expose as a parameter.

**Docs:**
- [Checkpointing and log pruning](https://neo4j.com/docs/operations-manual/current/database-internals/checkpointing/)

### R12. Cypher IP Blocklist -- Add 100.64.0.0/10

**Current state:** Blocklist covers RFC 1918, link-local, and IPv6 private
ranges but omits `100.64.0.0/10` (carrier-grade NAT / AWS shared services).

**Target state:** Append `100.64.0.0/10`.

---

## Implementation Plan

The plan is ordered so each step builds on the previous one and the template
stays deployable after every step.

### Step 1 -- Add a Persistent Data EBS Volume -- DONE

Implemented. Changes made to `neo4j.template.yaml`:

- Added `DataDiskSize` parameter (default 30 GB, min 20 GB) with SSD
  over-provisioning guidance in the description.
- Reduced root `DiskSize` default from 30 GB to 20 GB (OS + binaries only;
  20 GB is the minimum because the AMI snapshot is 20 GB).
- Added `Neo4jDataVolume` (`AWS::EC2::Volume`) with `DeletionPolicy: Retain`
  and `UpdateReplacePolicy: Retain` so it survives stack updates and instance
  replacement.
- Added `Neo4jVolumeAttach` IAM policy granting `ec2:AttachVolume`,
  `ec2:DetachVolume` (scoped to stack resources via tag condition) and
  `ec2:DescribeVolumes`.
- UserData attaches the volume, waits for the device (handles both `/dev/xvdf`
  and `/dev/nvme1n1` naming), formats as ext4 only on first boot, mounts at
  `/data` with `noatime,nodiratime`, and sets `server.directories.data=/data`.
- Password setup and auth-state clearing are conditional on first boot
  (`/data/databases/system` does not exist) so ASG replacement instances reuse
  the existing data and password.

### Step 2 -- Add a Persistent Transaction Log EBS Volume -- DONE

Implemented. Changes made to `neo4j.template.yaml`:

- Added `TxLogDiskSize` parameter (default 20 GB, min 10 GB) with a
  description explaining the I/O separation rationale.
- Added `Neo4jTxLogVolume` (`AWS::EC2::Volume`) with `DeletionPolicy: Retain`
  and `UpdateReplacePolicy: Retain`, same AZ, gp3, encrypted.
- UserData attaches the volume (`/dev/xvdg`), waits for the device (handles
  both `/dev/xvdg` and `/dev/nvme2n1` naming), formats as ext4 only on first
  boot, mounts at `/txlogs` with `noatime,nodiratime`, and sets
  `server.directories.transaction.logs.root=/txlogs`.
- No IAM changes needed — the existing `Neo4jVolumeAttach` policy covers all
  volumes tagged with the stack's `StackID`.

### Step 3 -- OS Hardening in UserData -- DONE

Implemented. Changes made to `neo4j.template.yaml` UserData:

- Added `swapoff -a` and removal of swap entries from `/etc/fstab` to
  prevent swap-induced latency spikes during memory-mapped I/O.
- Added a systemd override (`LimitNOFILE=60000`) for the neo4j service
  to raise the file descriptor limit from the Linux default of 1024.
- `systemctl daemon-reload` runs after the override is written and
  before Neo4j starts.

### Step 4 -- Update IAM Policy -- DONE (completed in Step 1)

### Step 5 -- Update DiskSize Parameter -- DONE (completed in Steps 1 & 2)

`DiskSize` updated in Step 1. `TxLogDiskSize` added in Step 2.

### Step 6 -- Add c6a Instance Types and Memory Guidance

**Goal:** Match Aura's production fleet and guide users on sizing.

Add compute-optimized types to `AllowedValues`:
```yaml
# Compute optimized (AMD gen 6) — query-heavy, dataset fits in memory
- c6a.large        # 2 vCPU,   4 GB
- c6a.xlarge       # 4 vCPU,   8 GB
- c6a.2xlarge      # 8 vCPU,  16 GB
```

Update `InstanceType` parameter description:
```yaml
Description: >
  EC2 instance type. t3.medium (4 GB) is the minimum for development.
  8 GB RAM or more is recommended for production workloads.
```

### Step 7 -- Add Cypher IP Blocklist Entry

**Goal:** Close the 100.64.0.0/10 gap.

Append `100.64.0.0/10` to the `internal.dbms.cypher_ip_blocklist` line in
UserData.

### Step 8 -- Add Graviton Instance Types (Optional)

**Goal:** Cost-performance improvement.

Add `t4g.*` and `r7g.*` to `AllowedValues` for `InstanceType`. Requires the
AMI to be built for `arm64`, so this step depends on AMI availability.

### Step 9 -- Validate

1. Deploy the updated stack.
2. Verify volumes are attached and mounted:
   ```bash
   lsblk
   df -h /data /txlogs
   ```
3. Verify neo4j.conf has correct directory settings (data + txlogs):
   ```bash
   grep server.directories /etc/neo4j/neo4j.conf
   ```
4. Terminate the instance and confirm the ASG launches a replacement that
   remounts the existing volumes with data intact.
5. Run a basic Cypher write/read test before and after replacement.
6. Confirm file descriptor limit: `cat /proc/$(pgrep -f neo4j)/limits`
7. Confirm swap is off: `free -h`
