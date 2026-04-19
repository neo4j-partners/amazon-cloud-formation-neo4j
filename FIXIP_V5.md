# FIXIP V5: Critical Review — Private-by-Default Implementation

Review of `neo4j-ee/worklog/nopublicip.md` and the corresponding implementation in `neo4j-ee/`. The purpose is to identify issues that will cause deployment failures or customer friction when the template is submitted to and deployed from AWS Marketplace. Issues are ordered by severity.

---

## Issue 1 — ec2messages VPC Endpoint Fails in Regions Launched After 2024

**Severity: Hard blocker for Marketplace submission.**

The template creates a VPC endpoint for the `ec2messages` service in Private mode. AWS removed this endpoint from every region launched in 2024 and later. The template will fail with `CREATE_FAILED` on the endpoint resource when a customer deploys in any of those newer regions.

The deploy script's test region list — us-east-1, us-east-2, us-west-2, eu-west-1, eu-central-1, ap-southeast-1, ap-southeast-2 — contains only pre-2024 regions. This is why the issue has not been caught. But Marketplace customers are not constrained to that list. Any customer deploying to ap-south-2, eu-south-2, il-central-1, or any other post-2024 region will see an immediate stack creation failure with no recoverable path.

The worklog does not mention this constraint. The nopublicip.md design spec lists `ec2messages` as a required endpoint without qualification. The endpoint must be made conditional on the region, or removed and replaced with the correct endpoint name for newer regions. The AWS documentation on SSM VPC endpoints distinguishes the behavior explicitly: older regions use `ec2messages`; newer regions use `ssmmessages` only, with `ec2messages` being unnecessary and unavailable.

---

## Issue 2 — Auto Scaling Group Has No Dependency on the Private Route Tables

**Severity: High. Causes silent boot failures in Private mode.**

The ASG can launch instances before the NAT Gateway routes are in place. NAT Gateways take two to three minutes to become available after creation. The private route table entries that route `0.0.0.0/0` through the NAT Gateways depend on the NAT Gateways being available, but CloudFormation does not wait for those route entries before launching ASG instances unless explicitly told to do so via `DependsOn`.

The UserData script runs with `set -euo pipefail`. If the instance boots before the route table is ready, every `yum install`, `aws ec2 describe-instances`, and `aws ssm put-parameter` call in the boot sequence will fail because there is no path to the internet or to AWS service endpoints. The `cfn-signal` at the end of UserData will never execute, CloudFormation will wait for the signal until the creation timeout expires, and the stack will fail.

This failure mode does not appear every time. Whether it manifests depends on the relative timing of NAT Gateway provisioning and ASG instance launch, which varies. It will occur reliably enough in Marketplace deployments to generate customer support cases.

The `Neo4jAutoScalingGroup` resource has no `DependsOn` pointing to `Neo4jPrivateSubnet1RouteTableAssociation` or the private route resources. The ASG also has no dependency on the SSM or S3 VPC endpoint creation, which means it can attempt SSM-dependent operations before those endpoints exist. The ASG needs explicit dependencies on the completion of all networking resources that the instance boot sequence relies on.

---

## Issue 3 — AllowedCIDR Has No Default Value in the Template

**Severity: Medium. Customer-facing UX regression from the design spec.**

The worklog (nopublicip.md) specifies that `AllowedCIDR` should default to `10.0.0.0/16` in Private mode, pointing out that a sensible default removes the burden from customers who are deploying into a fresh VPC and just want things to work. The actual template parameter has no `Default:` field.

In Marketplace deployments, every parameter without a default requires the customer to type a value before the stack will deploy. A customer who does not understand VPC CIDR notation — or who is deploying into a VPC they did not design — will either leave the field blank (which CloudFormation rejects), enter an incorrect value, or abandon the deployment. The default of `10.0.0.0/16` covers the RFC 1918 range used by the VPC created by the template itself. It is the right answer for the vast majority of first-time deployments.

This is a one-line fix but it represents a gap between the documented intent and the actual implementation.

---

## Issue 4 — NLB and Target Group Names Are Truncated by a Length Limit

**Severity: Medium. Deterministic failure for customers who use longer stack names.**

AWS imposes a 32-character limit on NLB names and Target Group names. The template constructs these names by concatenating the CloudFormation stack name with a suffix. The NLB suffix adds four characters, leaving 28 characters for the stack name. The target group suffixes add seven characters, leaving 24 characters.

A customer who deploys with a stack name longer than 24 characters will see `CREATE_FAILED` on the target group resources. This is not a theoretical edge case — a stack name like `neo4j-enterprise-production` is 27 characters and will cause the HTTP target group creation to fail.

The worklog does not address this constraint. The deploy script generates test stack names as `test-ee-<timestamp>`, which is 21 characters and stays under the limit. That means the limit has never been exercised by the test infrastructure.

---

## Issue 5 — Private Three-Node Cluster Consumes Three Elastic IP Addresses

**Severity: Medium. Exceeds default quota for customers who deploy multiple stacks.**

The three NAT Gateways in the Private three-node cluster each require one Elastic IP address. The default EIP quota in a new AWS account is five per region. A customer who has already allocated two EIPs for other purposes — a common situation — will see NAT Gateway creation fail when deploying the three-node Private cluster.

This is a soft limit, not a hard one: customers can request a quota increase. But the failure surface is invisible before deployment. The Marketplace listing should document that Private mode requires three Elastic IP addresses and link to the quota increase process.

---

## Issue 6 — Three-Node Cluster Assumes Three Availability Zones

**Severity: Medium. Violates AWS Marketplace AZ-independence requirement.**

The template allocates the three cluster nodes across three availability zones using `Fn::Select [2, Fn::GetAZs]` for the third subnet. AWS Marketplace requires CloudFormation templates to work in any region where the product is listed. Some older regions and some newer regions have fewer than three AZs. A customer deploying a three-node cluster in a region or account partition that exposes only two AZs will see `CREATE_FAILED` on the third subnet or NAT Gateway resource.

This failure is silent in the current test region set because all seven test regions have at least three AZs. The fix requires either a Marketplace listing restriction to regions with three or more AZs (which narrows the addressable market), or a template restructure that checks AZ availability and falls back gracefully.

---

## Issue 7 — No Successful End-to-End Test Run in Private Mode

**Severity: High. The only gate before Phase 6 (Marketplace submission) has not been passed.**

The nopublicip.md "Work Remaining" section names live deployment validation as the single remaining gate before Phase 6. The test run log in `FIX_SSM_WORK_LOG.md` documents three attempts, none of which produced a clean result. Run 1 failed due to the SSM `stdout=DEVNULL` bug. Run 2 and Run 3 were each disrupted by a newly introduced stage-2 TCP probe that corrupted the SSM tunnel's WebSocket state.

The SSM tunnel fix is in place in the current code: `stdout=subprocess.PIPE` with a drain thread, no stage-2 probe, `time.sleep(3)` after port bind. But the test suite has not been run against a fresh Private-mode stack with this fix applied. The tunnel fix was developed and documented during the same session that identified the RST regression — the fix has been written but not validated.

Every issue listed above in this review was discovered through code inspection and documentation research. The test suite catching these issues in a live run requires that the tunnel work, which in turn requires a successful Run 4. Until that run completes cleanly, the template's Private mode is unvalidated end to end.

---

## Issue 8 — Cluster Discovery and Instance Metadata Calls Route Through NAT

**Severity: Low. Design concern, not a blocker, but relevant to cost and reliability.**

During the multi-node boot sequence, each instance calls `aws ec2 describe-instances` and `aws autoscaling describe-auto-scaling-groups` to discover its cluster peers. These calls go through the NAT Gateway because there are no VPC endpoints for EC2 or Auto Scaling in the Private mode template.

The practical effect is that cluster formation traffic leaves the VPC, crosses the NAT Gateway, and returns through AWS's public endpoint infrastructure — adding latency, incurring NAT Gateway data processing charges, and creating a dependency on the NAT Gateway being fully operational before the first inter-node discovery call is made. VPC interface endpoints for EC2 and Auto Scaling would eliminate this path, but they come with their own hourly cost per AZ. For a three-node cluster across three AZs that is the standard deployment, the tradeoff should be evaluated against the frequency of cold-start boot sequences and the data volume of discovery calls.

This is not a Marketplace-blocking issue. It is an architectural decision that the design spec did not address.

---

## Summary

Two of these issues will cause deterministic stack creation failures under conditions that Marketplace customers will routinely encounter: the ec2messages endpoint in newer regions (Issue 1) and the name length limit for target groups (Issue 4). One issue — the ASG race condition on NAT routes (Issue 2) — will cause intermittent boot failures that are difficult to diagnose. Together, these three make the current template unsuitable for Marketplace submission in its current state.

The AllowedCIDR default (Issue 3), EIP quota documentation (Issue 5), AZ assumption (Issue 6), and NAT-routed discovery traffic (Issue 8) are all fixable and worth addressing before submission, but none of them are hard blockers.

The absence of a successful end-to-end test run (Issue 7) is the most important operational fact in this review. The three blockers above were found through inspection. Others may exist that only a live run would surface. Phase 6 should not begin until Run 4 — against a fresh Private-mode stack with the current tunnel fix — completes without error.
