# Scale to Zero: Sleep and Wake for Neo4j EE

## Summary

This proposal adds a sleep and wake feature to the Neo4j EE templates. A sleeping cluster runs zero EC2 instances. The data stays on the EBS volumes. A wake action brings the cluster back in about the time of a normal boot. A sleep action stops it again.

The first customer is a team that runs a month-end bill run. They use the graph a few days each month. They want AWS charges to follow the bill run.

The template already has most of the parts. Each node has its own Auto Scaling group. Each data volume has `DeletionPolicy: Retain`. Each new instance finds its volume by tag. A new instance already knows how to rejoin a cluster. The feature adds a controller that sets the group sizes to 0 or 1 in the right order.

Cost figures in this document are left out on purpose. Check list prices before you quote any number to a customer.

Paths below are relative to `neo4j-ee/`. Line numbers for `templates/neo4j-private.template.yaml` are written as `private:LINE`. Source partials live in `templates/src/`.

## What the code does today

These facts decide the design.

- **One group per server:** Each node has its own Auto Scaling group with MinSize, MaxSize, and DesiredCapacity set to 1. The groups sit at `templates/src/asg.yaml:15`, `:54`, and `:94`, with the sizes at `:27-29`, `:67-69`, and `:107-109`. The rendered lines are `private:711-828`.
- **Zero needs MinSize 0:** An Auto Scaling group cannot hold a desired capacity below its MinSize. The template must set MinSize to 0 before any tool can sleep a group.
- **One subnet per group:** Each group lists one subnet in `VPCZoneIdentifier` at `templates/src/asg.yaml:30-31`. A replacement instance always lands in the same Availability Zone as the one it replaces.
- **Volumes survive:** Each data volume has `DeletionPolicy: Retain` at `templates/src/ebs-volumes.yaml:20` and `:46`. Volumes live in three Availability Zones, one per node.
- **Volumes are found by tag:** The bootstrap looks up the volume by stack, role, and zone. It stops with an error unless it finds exactly one volume at `templates/src/partials/attach-data-volume.sh:19`.
- **Volumes are waited on:** The bootstrap waits up to 600 seconds for the volume to reach `available` at `templates/src/partials/attach-data-volume.sh:25-26`. A volume still attached to a dying instance delays the next boot.
- **First boot is detected by filesystem:** The script formats the disk and sets the initial password only when `blkid` finds no filesystem at `private:941-944`. A repeat boot on an existing volume keeps the data.
- **Every boot is a full install:** The bootstrap runs `yum -y install neo4j-enterprise` at `templates/src/partials/install-neo4j.sh:4`. The Private variant needs a NAT Gateway at wake time for this reason. The installed Neo4j version can also change between wake cycles.
- **Peer discovery is time limited:** `configure_cluster` tries 30 times with a 10 second pause at `templates/src/partials/configure-neo4j.sh:56` and `:68`. It fails after about 5 minutes at `:73` if it sees fewer instances than the node count. It counts instances in any lifecycle state. All three groups must start close together, and they must start only after the old instances are gone.
- **Load balancer checks are TCP:** Both target groups use `HealthCheckProtocol: TCP` at `templates/src/networking-private.yaml:453` and `:482`. A healthy target proves that a port is open. Wake must also run a Bolt query to prove that Neo4j answers.
- **Deregistration delay is the default:** No `deregistration_delay` attribute exists in `TargetGroupAttributes` at `templates/src/networking-private.yaml:458` and `:484`. The default is 300 seconds.
- **Signals run on every boot:** `userdata.sh` sends `cfn-signal --success true` at line 45 after the bootstrap. The ERR trap at line 17 sends a failure signal without `|| true`. Whether a signal to an already finished resource raises an error is unverified. See the open questions.
- **No S3 and no scheduling today:** `Neo4jRole` has no S3 permission, see `templates/src/iam.yaml`. The template has no Step Functions, Lambda, EventBridge, or backup resource.
- **Seed providers are set:** `neo4j-base.conf:13` enables `CloudSeedProvider`. It lets a database seed from an S3 URI once the role can read the bucket.
- **Backup has no config today:** `neo4j-base.conf` holds no backup key. The default backup listener setting needs a check against the Neo4j version in use.

## Idle cost while asleep

The compute cost drops to zero. These resources keep running and keep billing.

- **NAT Gateways:** The Private template creates three NAT Gateways and three Elastic IPs at `private:1515-1568`. The Existing VPC template creates none.
- **Interface endpoints:** The Private template creates four interface endpoints, each in three subnets, at `private:1924-1986`. The Existing VPC template makes them optional through `CreateVpcEndpoints`.
- **Load balancer:** The internal NLB at `private:1722` bills by the hour.
- **Bastion:** The SSM bastion is a t4g.small instance at `private:1872-1922`.
- **Flow logs:** VPC flow logs write to CloudWatch at `private:2147-2187`.
- **Data volumes:** The three gp3 volumes request 4000 IOPS and 250 MB/s at `templates/src/ebs-volumes.yaml:27-28`. The base gp3 level is 3000 IOPS and 125 MB/s, so the extra capacity adds a charge.
- **Root volumes:** The 20 GB root volume of each node ends with its instance, so it adds no idle charge.

## Design

The design uses one Step Functions state machine with two actions.

- **Wake action:** The state machine confirms all groups hold zero instances. It then sets MinSize 1 and DesiredCapacity 1 on all three groups at the same time. It polls until every group shows an InService instance. It then runs a Bolt query on one node and polls until the cluster reports all servers.
- **Sleep action:** The state machine takes a backup, stops the Neo4j service on each node, sets MinSize 0 and DesiredCapacity 0 on all groups at the same time, and polls until every group holds zero instances.
- **Callers:** A bill-run pipeline calls `StartExecution`. An optional EventBridge Scheduler rule calls the same state machine on a cron schedule.
- **Failure alarm:** A CloudWatch alarm on failed executions notifies the existing alert topic.

The state machine type is Standard. A Standard workflow can run for up to a year. The sleep and wake actions use AWS SDK integrations for Auto Scaling and SSM. The polling steps use a Wait state and a loop.

## Needed changes

Every change below keeps to the build rule. Edit the partial, register it in `templates/build.py`, and run `python build.py`. Commit the partial and the regenerated `templates/neo4j-*.template.yaml` files together.

- **New parameter `EnableSleepWake`:** Add it to `templates/src/parameters-common.yaml` with values `true` and `false` and the default `false`.
- **New condition `SleepWakeEnabled`:** Add it to `templates/src/conditions-private.yaml`, `conditions-existing-vpc.yaml`, and `conditions-public.yaml`.
- **New parameter group:** Add `EnableSleepWake`, `WakeSchedule`, `SleepSchedule`, `ScheduleTimezone`, `DataVolumeIops`, and `DataVolumeThroughput` to the Interface section of `templates/src/metadata-private.yaml`, `metadata-existing-vpc.yaml`, and `metadata-public.yaml`.
- **New parameters `WakeSchedule`, `SleepSchedule`, and `ScheduleTimezone`:** Add them to `templates/src/parameters-common.yaml`. An empty schedule creates no schedule resource.
- **New parameters `DataVolumeIops` and `DataVolumeThroughput`:** Add them to `templates/src/parameters-common.yaml`. Use them in `templates/src/ebs-volumes.yaml` at lines 27-28, 52-53, and 77-78.
- **ASG sizes:** In `templates/src/asg.yaml`, `asg-existing-vpc.yaml`, and `asg-public.yaml`, set `MinSize: !If [SleepWakeEnabled, 0, 1]` on `Neo4jNode1ASG`, `Neo4jNode2ASG`, and `Neo4jNode3ASG`.
- **ASG update policy:** In the same three files, add `UpdatePolicy: AutoScalingScheduledAction: IgnoreUnmodifiedGroupSizeProperties: true` to each ASG.
- **ASG health grace:** Leave `HealthCheckGracePeriod` at 1200 in the same three files.
- **Target group delay:** In `templates/src/networking-private.yaml`, `networking-existing-vpc.yaml`, and `networking-public.yaml`, add `deregistration_delay.timeout_seconds` to `TargetGroupAttributes` on `Neo4jBrowserTargetGroup` and `Neo4jBoltTargetGroup`.
- **New partial `sleep-wake.yaml`:** Create `templates/src/sleep-wake.yaml`. It holds the backup bucket, the state machine, the state machine role, the schedule resources, and the failure alarm. Register it in `resource_partials` for `_PRIVATE_SPEC`, `_PUBLIC_SPEC`, and `_EXISTING_VPC_SPEC` in `templates/build.py`.
- **Backup bucket:** In `sleep-wake.yaml`, add `Neo4jBackupBucket` with encryption, a public access block, versioning, a lifecycle rule, and `DeletionPolicy: Retain`.
- **Instance role:** In `templates/src/iam.yaml` and `iam-public.yaml`, add an S3 policy on `Neo4jRole` for `Neo4jBackupBucket`. Add `ssm:SendCommand` permission only if a step needs it from the node. The role already carries SSM core.
- **State machine:** In `sleep-wake.yaml`, add `Neo4jSleepWakeStateMachine` and `Neo4jSleepWakeRole`.
- **Schedules:** In `sleep-wake.yaml`, add `Neo4jWakeSchedule`, `Neo4jSleepSchedule`, and their scheduler role. Guard each with a condition on its schedule parameter.
- **Failure alarm:** In `sleep-wake.yaml`, add an alarm on `ExecutionsFailed` for the state machine. Point it at the SNS topic defined near `templates/src/observability.yaml:79`.
- **Backup setting:** Add the backup listener key to `templates/src/neo4j-base.conf` only if the Neo4j default is off for the shipped version. The Placement Decision Rule sends fixed keys to this file.
- **Bastion sleep step:** In `sleep-wake.yaml`, give the state machine permission to stop and start `Neo4jOperatorBastion` in the Private and Existing VPC variants.
- **Single NAT option:** In `templates/src/parameters-private.yaml` and `networking-private.yaml`, add `NatGatewayMode` with values `PerAz` and `Single`. Change the private route resources near `networking-private.yaml:156` to follow it.
- **SSM parameters:** In `templates/src/stack-config.yaml`, `stack-config-existing-vpc.yaml`, and `stack-config-public.yaml`, add `/neo4j-ee/${StackName}/sleepwake/state-machine-arn` and `/neo4j-ee/${StackName}/sleepwake/backup-bucket`.
- **Outputs:** In `templates/src/outputs-private.yaml`, `outputs-existing-vpc.yaml`, and `outputs-public.yaml`, add `Neo4jSleepWakeStateMachineArn` and `Neo4jBackupBucketName`.
- **Contract tests:** In `tests/test_template_partials.py`, add tests for the new parameter, the MinSize condition, the update policy, and the absence of any change to `assert_security_invariant`.
- **Operator tooling:** In `validate-private/`, add `sleep` and `wake` commands that start the state machine and wait for it.
- **Architecture doc:** In `docs/architecture/template-architecture.md`, add a short section that places the controller in the Template layer.
- **Deploy script:** In `deploy.py`, add `--enable-sleep-wake`, `--wake-schedule`, and `--sleep-schedule` flags.

## Technical detail per change

### ASG sizes and update policy

The ASG must accept a desired capacity of 0. That needs MinSize 0. With `EnableSleepWake` set to `false`, MinSize stays 1 and current behavior holds.

The default CloudFormation behavior resets group sizes to the template values on every update. The CloudFormation reference says this applies even when a scheduled action is in effect. A stack update would therefore wake a sleeping cluster. It would also launch three instances at once.

The `AutoScalingScheduledAction` policy with `IgnoreUnmodifiedGroupSizeProperties: true` stops that reset. The reference says CloudFormation then keeps the live sizes unless the template changes them. The page describes the policy for groups that have a scheduled action. It does not say what happens for a group without one. A spike must confirm the behavior. The fallback is a stack parameter `ClusterState` with values `Awake` and `Asleep` that sets the sizes in the template. The state machine would then also update the stack, which is slower.

A launch template change while the cluster sleeps replaces nothing, because no instance exists. The next wake uses the new launch template version. This is a good property. It lets an operator apply a template update to a sleeping cluster at no risk.

### State machine: Wake

1. Describe all three groups. Check that each holds zero instances in any state. This protects peer discovery, which counts instances in any lifecycle state.
2. Update all three groups in a Parallel state to MinSize 1 and DesiredCapacity 1. Parallel start keeps all three instances inside the 5 minute discovery window.
3. Poll the groups every 30 seconds until each has one InService instance. Fail the execution after 40 minutes.
4. Send an SSM command to one node that runs `cypher-shell` with the password from Secrets Manager and returns the result of `SHOW SERVERS`. The node role already reads the secret and already runs SSM.
5. Poll until the command shows all servers enabled and available.
6. Optionally describe target health on both target groups as a second check.

The Bolt check runs on a node. That keeps it working in the Public variant, which has no bastion.

### State machine: Sleep

1. Pick one node. Run `neo4j-admin database backup` there with an S3 `--to-path`.
2. Poll the SSM command until it succeeds. Fail the execution if it fails. A failed backup leaves the cluster awake.
3. Run `systemctl stop neo4j` on all three nodes through SSM. Wait for success.
4. Update all three groups in a Parallel state to MinSize 0 and DesiredCapacity 0.
5. Poll until every group holds zero instances.
6. Stop the bastion with `ec2:StopInstances` when the variant has one.

The Neo4j manual documents `neo4j-admin database backup --to-path=s3://bucket/dir/` for cloud storage. The manual also says the command needs a local `--temp-path` with space for the store files and transaction logs. The node root volume is 20 GB, so the command should write its temporary files to the data volume.

A data volume attached with `AttachVolume` normally detaches on termination and keeps its data. The test plan confirms this on a real stack.

### Backup bucket and role policy

The backup is a safety copy. The retained EBS volumes already hold the data across sleep. The S3 copy covers the case where a cold restart of all three nodes fails to form a cluster. The state machine takes the backup as the first Sleep step. A parameter can skip it for customers who want faster sleep.

`Neo4jRole` receives `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on the one bucket. The manual lists these actions for S3 backups. In the Private variant, the S3 gateway endpoint at `private:1988` keeps backup traffic inside the VPC. The Existing VPC template creates no S3 gateway endpoint, so the caller's VPC must give the nodes a route to S3.

### Schedules

EventBridge Scheduler supports cron expressions in a chosen IANA time zone. The day-of-month field accepts `L` for the last day and `W` for the nearest weekday. A schedule such as `cron(0 6 L * ? *)` runs at 06:00 on the last day of each month. Scheduler invokes targets within a 60 second window. It adjusts for daylight saving time.

The schedule resources stay optional. A bill-run pipeline that calls `StartExecution` needs no schedule at all. The pipeline reads the ARN from the SSM parameter or the stack output.

### Data volume IOPS and throughput

The two new parameters feed `templates/src/ebs-volumes.yaml`. The defaults match today's values of 4000 and 250. Existing stacks see no change on update. The month-end customer sets 3000 and 125 to drop the extra charge. gp3 supports an in-place change of both values.

### Bastion

The simplest sleep path is to stop the bastion. A stopped EC2 instance bills for its root volume only. `Neo4jOperatorBastion` stays an `AWS::EC2::Instance`, so no resource type changes and `validate-private` keeps working. The state machine starts the bastion at the end of Wake and stops it at the end of Sleep. An Auto Scaling group for the bastion would add a resource replacement and gives little extra.

### Single NAT option

`NatGatewayMode: Single` creates one NAT Gateway and routes all three private subnets through it. This cuts two NAT Gateways and two Elastic IPs. The cost is a cross-zone dependency. If the zone that holds the NAT fails, the other zones lose internet. A running cluster needs internet only for AWS API calls that the endpoints do not cover. A waking cluster needs it for the Neo4j install. The default stays `PerAz`.

### Target group delay

A lower `deregistration_delay.timeout_seconds` shortens the time that a draining target stays registered. Sleep stops Neo4j before termination, so no connection needs a long drain. A value of 30 seconds is a reasonable start.

## Is one ASG per server the right design?

Yes. Keep one group per server. The reasons come from the code.

- **EBS volumes belong to one zone:** A volume in `us-east-1a` attaches only to an instance in `us-east-1a`. The volumes use `!Select [0..2, GetAZs]` in `templates/src/ebs-volumes.yaml`.
- **Each group has one subnet:** `VPCZoneIdentifier` lists a single subnet in `templates/src/asg.yaml:30-31`. A replacement lands in the same zone as its volume.
- **The bootstrap expects one volume per zone:** The check at `templates/src/partials/attach-data-volume.sh:19` fails the boot when the zone holds zero or two volumes.
- **A shared group could move instances:** A multi-zone group can rebalance across zones. It terminates an instance in one zone and launches another in a different zone. The new instance finds a volume that belongs to a node that is still alive, or finds none.
- **A shared group cannot bind an instance to a volume:** The group picks the zone. It does not pick the node. Extra logic would be needed to map each launch to the right volume.
- **One group saves little work:** One group would let a single API call set all sizes. The three parallel calls in this design cost little, so the gain is small.

## Warm pools

A warm pool keeps pre-initialized instances beside a group. The pool state can be `Stopped`. The Auto Scaling documentation says a stopped instance bills for its volumes and Elastic IP addresses only. The documentation also says that `ReuseOnScaleIn` lets a scaled-in instance return to the pool instead of terminating.

This looks attractive for scale to zero.

- **No install at wake:** A stopped instance already has Neo4j installed. Wake skips the yum install, so the Private variant needs no NAT during wake.
- **Same private IP:** A stopped instance keeps its private IP. The cluster endpoint list stays valid.
- **Same volume:** The data volume stays attached to the stopped instance.
- **Faster wake:** An instance start is faster than a cold boot and a full install.

These points need a spike before the design relies on them.

- **Pool size follows the maximum:** The documentation sets the default pool size to MaxSize minus DesiredCapacity. With MaxSize 1 and desired 0, the pool holds 1 instance, which fits. With a custom size above that, the pool would launch a second instance per zone that competes for the same volume.
- **User data runs once:** cloud-init runs user data on the first boot only. A restarted instance would not rerun the bootstrap. The documentation lists a `scripts-user, always` option that reruns it. Neo4j would need to start from systemd alone, and `start_neo4j` would need to set that up. This has not been checked.
- **Lifecycle hooks:** The documentation says to add a launching hook so the instance finishes its bootstrap before it enters the pool. This template signals through `cfn-signal`, so a hook adds a second completion path next to the single `cfn-signal` owner.
- **Stale software:** A stopped instance keeps the Neo4j version and launch template from the day it stopped. An instance refresh replaces pool instances after a template update. That refresh would also change the sleeping cluster.
- **Capacity on start:** The documentation says an instance in an out-of-capacity zone can fail to start. The group then retries with a cold launch.
- **Cost while asleep:** The pool adds root volume charges per node. Compute stays at zero.

The recommendation is to ship the cold wake first. It follows the replacement path the stack already uses and carries the fewest new moving parts. Run a warm pool spike on a test stack after the first release. If the spike passes, add `SleepMode` with values `Terminate` and `WarmPool`.

## Test plan

Run each step on a real stack. Use the Private variant first, then Existing VPC, then Public.

1. **Template contract tests:** Run `python -m unittest discover -s tests` and `python build.py --verify`.
2. **Lint:** Run `cfn-lint` on all three templates.
3. **Deploy:** Run `./deploy.py --enable-sleep-wake` with three nodes.
4. **Baseline:** Run `uv run preflight` and `uv run validate-private`. Write a marker node.
5. **Sleep:** Start the Sleep execution. Check that the backup object exists in S3. Check that all groups show zero instances and all three volumes show `available`.
6. **Volume check:** Confirm each volume kept its data and tags after termination.
7. **Idle check:** Confirm only the expected resources remain billable.
8. **Wake:** Start the Wake execution. Record the time from start to a successful `SHOW SERVERS`.
9. **Data check:** Read the marker node. Run `uv run scripts/smoke-write.py`.
10. **Release suite:** Run `uv run validate-private --suite release` after wake.
11. **Cold cluster test:** Repeat sleep and wake five times. Check that all nodes reach `Enabled` each time with new private IPs.
12. **Stack update while asleep:** Change a harmless parameter. Confirm the groups stay at 0. This tests the update policy.
13. **Stack update while awake:** Repeat. Confirm the groups stay at 1.
14. **Failure paths:** Break the backup bucket policy and confirm Sleep fails and the cluster stays awake. Start Wake while an instance is still terminating and confirm the first step refuses.
15. **Signal check:** Confirm that a boot after stack creation finishes cleanly through `cfn-signal`.
16. **Restore test:** Seed a new database from the S3 backup. This confirms the safety copy works.
17. **Schedule test:** Create a schedule five minutes ahead. Confirm the execution starts.
18. **Warm pool spike:** After the main tests pass, repeat steps 5 to 9 on a stack with a Stopped warm pool.

## Open questions

- **Cold cluster restart:** The repository holds no test that stops a full three node cluster and starts it again with new private IPs. Step 11 of the test plan answers this. The S3 backup is the fallback.
- **Post-create boots and `cfn-signal`:** A boot after creation sends another success signal to a finished resource. The ERR trap sends a failure signal without `|| true`. If the signal call raises an error, `alternatives --install` at `templates/src/userdata.sh:46` does not run. Neo4j already runs by then. A test on a replaced instance decides whether this needs a `|| true` guard.
- **Update policy without a scheduled action:** The CloudFormation reference describes `IgnoreUnmodifiedGroupSizeProperties` for groups that have a scheduled action. Step 12 of the test plan checks the behavior without one.
- **Neo4j backup settings:** The Neo4j manual documents S3 backup destinations. The first Neo4j version with that support, the default backup listener address, and the behavior in a three node cluster need checking against the version in the AMI.
- **Existing VPC S3 route:** The Existing VPC template creates no S3 gateway endpoint. The proposal needs a rule for how nodes reach S3 there.
- **Neo4j version drift:** Each wake installs the newest package from `yum.neo4j.com/stable/latest`. A pinned version parameter would make wake repeatable. This is outside the sleep and wake change.
- **Load balancer health check:** `docs/architecture/template-architecture.md` describes an L7 health check. The templates use TCP. The architecture doc needs a correction, and the Wake check on Bolt covers the gap.
- **Volume defaults:** Should `DataVolumeIops` and `DataVolumeThroughput` default to today's values or to the gp3 base values? Today's values keep existing stacks unchanged.
- **Backup on every sleep:** Should the backup run on every Sleep, or only when a parameter asks for it?
- **Warm pool:** Should the first release include the spike, or follow it?
- **Alert topic:** `HasAlertEmail` controls the SNS topic near `templates/src/observability.yaml:51-79`. The failure alarm needs a rule for stacks that have no alert email.
- **Tooling lookups:** `validate-private` scripts may read the bastion or ASG state in ways that fail on a sleeping stack. A pass over `validate-private/` is needed.
