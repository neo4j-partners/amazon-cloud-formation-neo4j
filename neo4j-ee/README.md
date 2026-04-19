# Neo4j Enterprise Edition — AWS Marketplace

CloudFormation template and tooling for the Neo4j Enterprise Edition AWS Marketplace listing. Supports single-instance and three-node cluster deployments fronted by a Network Load Balancer.

## Quick Start — CLI Deployment

All scripts read `AWS_PROFILE` from the environment and fall back to the `default` profile if it is not set. Set it once before running any commands:

```bash
export AWS_PROFILE=<your-profile>   # omit entirely to use your default AWS profile
```

> **Marketplace publishing scripts only** (`marketplace/create-ami.sh`, `marketplace/test-ami.sh`): these must run against the `neo4j-marketplace` AWS account (account `385155106615`). Set `AWS_PROFILE=marketplace` before running them. All other scripts (`deploy.sh`, `teardown.sh`, `test-observability.sh`) work with any account that has CloudFormation, SSM, EC2, and IAM permissions.

### 1. Deploy the Stack

There are two AMI modes depending on what you're testing.

**Marketplace mode** — validates what a live customer receives. The template's published Marketplace AMI is used directly. No local AMI file needed:

```bash
./deploy.sh --marketplace                                                           # t3.medium, 3 nodes, random region, Private mode
./deploy.sh --marketplace r8i                                                       # memory optimized (r8i.xlarge)
./deploy.sh --marketplace --number-of-servers 1                                     # single instance
./deploy.sh --marketplace --region eu-west-1                                        # specific region
./deploy.sh --marketplace r8i --region us-east-2 --number-of-servers 3
./deploy.sh --marketplace --alert-email you@example.com                             # enable CloudWatch alarm emails
./deploy.sh --marketplace --mode Public                                             # internet-facing NLB (opt-in)
```

**Local AMI mode** — tests a newly built AMI before it is published to the Marketplace. Requires the `neo4j-marketplace` account. Build and verify the AMI first:

```bash
AWS_PROFILE=marketplace ./marketplace/create-ami.sh     # builds AMI, writes ID to marketplace/ami-id.txt
AWS_PROFILE=marketplace ./marketplace/test-ami.sh       # verifies SSH hardening and OS (no SSH key needed)
```

Then deploy using that AMI (switch back to your test account profile):

```bash
./deploy.sh                                                            # t3.medium, 3 nodes, random region, Private mode
./deploy.sh r8i                                                        # memory optimized (r8i.xlarge)
./deploy.sh --number-of-servers 1                                      # single instance
./deploy.sh --region eu-west-1                                         # specific region (AMI auto-copied)
./deploy.sh r8i --region us-east-2 --number-of-servers 3
./deploy.sh --alert-email you@example.com                              # enable CloudWatch alarm emails
./deploy.sh --mode Public                                              # internet-facing NLB (opt-in)
```

In local AMI mode the script creates a temporary SSM parameter for the AMI ID and copies the AMI cross-region if needed. Cross-region copies can take 10-20+ minutes — use `--region us-east-1` to skip the copy.

When `--alert-email` is provided, AWS sends a confirmation email to that address after the stack is created. Click the link in that email to activate the SNS subscription before CloudWatch alarm notifications will be delivered.

Multiple deployments can coexist — each gets its own output file in `.deploy/`.

To look up connection details for a deployed stack directly from CloudFormation:

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --region <region> \
  --query 'Stacks[0].Outputs' \
  --output table
```

This returns the NLB DNS name, Bolt URI, and username.

### 2. Test Observability

`test-observability.sh` verifies the Phase 1 observability components that the CloudFormation template provisions: CloudWatch agent, application log streams, VPC flow logs, failed-auth alarm, and CloudTrail.

```bash
./test-observability.sh                                  # all steps, most recent deployment
./test-observability.sh <stack-name>                     # all steps, specific stack
./test-observability.sh --step <name>                    # single step, most recent deployment
./test-observability.sh <stack-name> --step <name>       # single step, specific stack
```

Valid step names:

| Name | What it checks |
|---|---|
| `cloudwatch` | CloudWatch agent active on all nodes (via SSM) |
| `logs` | Application log group exists with the expected stream count |
| `flowlogs` | VPC flow log group exists and has ENI streams |
| `alarm` | Failed-auth alarm transitions to ALARM after 12 bad login attempts |
| `cloudtrail` | A multi-region CloudTrail trail exists and is logging |

The `alarm` step takes up to 7 minutes (5-minute CloudWatch evaluation window). All other steps complete in under a minute. SNS email delivery is flagged as a manual step in the summary — see `TESTING_GUIDE.md` for instructions.

### 3. Connect to a Private Deployment

For a complete operator walkthrough — retrieving the password, opening an admin shell, running the validation suite, and troubleshooting — see [`PRIVATE_ACCESS_GUIDE.md`](PRIVATE_ACCESS_GUIDE.md).

Private mode (the default) places instances in private subnets with no public IP and an internal NLB. Public mode places instances in public subnets with an internet-facing NLB — useful for demos and development.

#### Driver URI scheme and cluster routing

Neo4j drivers support two URI schemes with different connection semantics:

- **`bolt://`** — connects directly to the specified host and port. No routing table is fetched. All requests go to that single host.
- **`neo4j://`** — uses the Bolt routing protocol. The driver fetches a routing table on first connect, listing writers, readers, and routers. Subsequent requests are distributed across cluster members.

**How the template configures routing**

At boot each cluster node sets two `neo4j.conf` values:

```
server.bolt.advertised_address = <nlb-dns>:7687
dbms.routing.default_router    = SERVER
```

`server.bolt.advertised_address` controls the address this node advertises in routing tables — set to the NLB DNS rather than the node's own private IP. `dbms.routing.default_router=SERVER` tells the node to return a one-entry routing table (the NLB) instead of the full list of cluster member IPs. Any driver connecting with `neo4j://` will receive a routing table containing the NLB DNS name and will send all subsequent requests back through the NLB, which distributes across nodes and lets Neo4j server-side routing handle write vs. read direction internally.

**URI scheme by access pattern**

| Access pattern | Recommended URI | Notes |
|---|---|---|
| Same VPC | `neo4j://<nlb-dns>:7687` | Routing table returns NLB DNS; driver stays on NLB; full cluster failover |
| Peered VPC / Transit Gateway | `neo4j://<nlb-dns>:7687` | NLB DNS resolves to private IPs reachable through the peering route |
| SSM tunnel | `bolt://localhost:7687` | Skips routing table; simple and reliable for operator access |
| SSM tunnel + routing scheme | `neo4j://localhost:7687` with custom resolver | Routing table returns NLB DNS, which resolves to private IPs not routable from the laptop; fails without a custom resolver (see below) |
| Direct node IP (same subnet) | `bolt://<node-ip>:7687` | Bypasses NLB; single node only, no failover — see production patterns below |

**`neo4j://` through an SSM tunnel requires a custom resolver**

Via SSM, the driver connects to `localhost:7687`. The server returns a routing table with the NLB DNS name (e.g., `internal-xxxx.elb.amazonaws.com:7687`). The driver tries to open new connections to that address, which resolves to private IPs inside the VPC — not routable from the operator's laptop. Subsequent requests fail.

The simplest fix is `bolt://localhost:7687` for SSM access. If `neo4j://` is required (for example, a CI runner that must exercise cluster routing), implement a custom resolver that maps the NLB DNS back to `localhost`:

```python
# Python driver — custom resolver for SSM tunnel
from neo4j import GraphDatabase

def resolver(address):
    return [("localhost", 7687)]

driver = GraphDatabase.driver(
    "neo4j://localhost:7687",
    auth=("neo4j", password),
    resolver=resolver
)
```

The custom resolver pattern is available in all official Neo4j drivers.

**References:** [Leadership, routing, and load balancing](https://neo4j.com/docs/operations-manual/current/clustering/setup/routing/) · [Configure network connectors — `server.bolt.advertised_address`](https://neo4j.com/docs/operations-manual/current/configuration/connectors/)

#### From an operator workstation (SSM port-forward)

For interactive access from a laptop or CI runner, use AWS Systems Manager Session Manager port-forwarding. In Private mode the stack provisions a dedicated operator bastion (`t4g.nano`) whose only purpose is to carry these tunnels — see ["Why the operator bastion exists"](#why-the-operator-bastion-exists-nlb-hairpin) at the bottom of this document.

**Prerequisite:** install the Session Manager Plugin alongside the AWS CLI:

```bash
# macOS
brew install --cask session-manager-plugin

# or download from AWS:
# https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
```

To connect manually, copy the ready-to-run commands from the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> --region <region> \
  --query 'Stacks[0].Outputs[?OutputKey==`Neo4jSSMHTTPCommand` || OutputKey==`Neo4jSSMBoltCommand`].[OutputKey,OutputValue]' \
  --output table
```

Each command already has the bastion instance ID and NLB DNS substituted — just run them in two terminals (or backgrounded with `&`). Then open `http://localhost:7474` in a browser or connect `bolt://localhost:7687`.

> **Note:** Connection strings generated inside Neo4j Browser (the "Connect URL" field and copy-paste URIs) will show the internal NLB DNS hostname rather than `localhost`. Substitute `localhost` for the hostname to connect through the open tunnel.

#### From application workloads (production patterns)

Application tiers inside AWS reach the internal NLB directly without SSM tunnels. AWS Network Load Balancers support connections from clients over VPC peering, AWS managed VPN, Direct Connect, and third-party VPN solutions.

**Same VPC** — an application running in the same VPC connects to the NLB's internal DNS name on port 7687 (Bolt) or 7474 (HTTP). Set `AllowedCIDR` to `10.0.0.0/16` (the VPC CIDR) at stack launch — no additional security group changes are needed for in-VPC clients.

**VPC Peering / Transit Gateway** — an application in a spoke VPC reaches the NLB's private IP addresses through the peering or TGW route. Two prerequisites: (1) a route in the spoke VPC's route table pointing the Neo4j VPC CIDR at the peering connection or TGW attachment, and (2) `AllowedCIDR` must be updated at stack launch to include the spoke VPC's CIDR (e.g. `10.1.0.0/16`). The NLB DNS resolves directly to private IPs; no additional DNS configuration is required on the peering connection.

**Within the same subnet** — an application in the same subnet can connect directly to individual Neo4j node IPs on port 7687, bypassing the NLB. Use `bolt://<node-ip>:7687`; see [Driver URI scheme and cluster routing](#driver-uri-scheme-and-cluster-routing) for why `neo4j://` should not be used with a direct node IP.

### 4. Tear Down

```bash
./teardown.sh                  # tears down the most recent deployment
./teardown.sh <stack-name>     # tears down a specific deployment
```

> **Note:** Private mode provisions NAT Gateways (1 for single-instance, 3 for cluster), which incur hourly charges. Tear down promptly after testing.

Deletes the CloudFormation stack, the SSM parameter created in local AMI mode, any cross-region AMI copy, and removes the deployment file from `.deploy/`. In `--marketplace` mode only the stack and output file are deleted (no SSM parameter or copied AMI to clean up).

## What Gets Deployed

The `DeploymentMode` parameter (default: `Private`) controls network placement.

### Private mode (default)

Instances have no public IP and no direct internet exposure. NAT Gateways provide outbound-only internet access (for package updates, etc.). Access is via SSM Session Manager port-forwarding.

**Three-node cluster** (`NumberOfServers=3`):
- VPC with three public subnets (NAT Gateways) and three private subnets (EC2 instances), one pair per AZ
- Internal Network Load Balancer across the three private subnets
- Three NAT Gateways (one per AZ) for cluster-member outbound traffic
- Three EC2 instances in private subnets forming a Causal Cluster with Raft consensus
- One `t4g.nano` operator bastion in a private subnet for SSM port-forward tunnels (not registered as an NLB target — see ["Why the operator bastion exists"](#why-the-operator-bastion-exists-nlb-hairpin))
- External security group allowing inbound on 7474 and 7687 from `AllowedCIDR`
- Internal security group restricting cluster ports (5000, 6000, 7000, 7688, and others) to cluster members only

**Single instance** (`NumberOfServers=1`):
- VPC with one public subnet (NAT Gateway) and one private subnet (EC2 instance)
- Internal Network Load Balancer in the private subnet
- One NAT Gateway for outbound traffic
- One EC2 instance in a private subnet
- One `t4g.nano` operator bastion in a private subnet for SSM port-forward tunnels

### Public mode (`--mode Public`)

Instances receive public IP addresses and the NLB is internet-facing. Use for development or when a VPN/private network is not available.

**Three-node cluster** (`NumberOfServers=3`):
- VPC with three public subnets, one per Availability Zone
- Internet-facing Network Load Balancer across all three subnets
- Three EC2 instances with public IPs forming a Causal Cluster with Raft consensus
- External security group allowing inbound on 7474 (Browser/HTTP) and 7687 (Bolt) from `AllowedCIDR`
- Internal security group restricting cluster ports to cluster members only

**Single instance** (`NumberOfServers=1`):
- VPC with a single public subnet
- Internet-facing Network Load Balancer in that subnet
- One EC2 instance with a public IP

### Common to both modes

The NLB DNS name is the stable endpoint in all configurations. The Neo4j driver connects to port 7687 on the NLB and the cluster handles request routing internally. In Private mode, connect via an SSM port-forward tunnel — the test suite handles this automatically.

**Security configuration:**

| Setting | Default | Notes |
|---|---|---|
| `DeploymentMode` | `Private` | `Private`: instances in private subnets, internal NLB, NAT Gateways. `Public`: public IPs, internet-facing NLB. |
| `AllowedCIDR` | *(required)* | CIDR allowed to reach ports 7474 and 7687. Private mode: enter `10.0.0.0/16`. Public mode: enter the CIDR of the clients that should reach the NLB. `0.0.0.0/0` is not accepted. |
| IMDSv2 | enforced | Instance metadata requires session tokens; IMDSv1 requests are rejected. |
| JDWP (port 5005) | disabled | Remote debug port is closed and the JVM debug flag is stripped from `neo4j.conf` at boot. |
| Internal cluster ports | self-referencing | Ports 5000, 6000, 7000, 7688, and others are reachable only from other cluster members. |

## TLS on Bolt

The template can provision TLS on the Bolt connector (port 7687) from a customer-supplied certificate. When the `BoltCertificateSecretArn` parameter is set, Neo4j is configured with `server.bolt.tls_level=REQUIRED` and `dbms.ssl.policy.bolt.*` against the cert and key in the named Secrets Manager secret. When the parameter is empty (the default), Bolt runs as plain TCP — appropriate for internal-only deployments where the VPC/SG boundary is the trust boundary.

Phase 1 covers Bolt only. The HTTP browser endpoint (7474) and cluster-internal ports (6000/7000/7688) remain plaintext (see [Residual risk](#residual-risk--cluster-replication-traffic) below).

### Secret format

Create a single Secrets Manager secret whose `SecretString` is JSON:

```json
{
  "certificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
}
```

Both fields are required. UserData validates the JSON shape on boot and fails the stack with a clear error if either field is missing. Either field may hold an ACM Private CA-issued PEM — no separate parameter is needed.

The default `aws/secretsmanager` AWS-managed key is sufficient for Phase 1. Customer-managed KMS keys (per-key audit trail, fine-grained revocation) are a Phase 2 hardening option.

### Production guidance — customer-owned DNS (Option B)

The recommended production pattern uses a stable customer-owned DNS name in front of the NLB so certs are not pinned to the AWS-generated NLB DNS:

1. **Create a stable name for Neo4j.** Route53 private hosted zone with an A-record alias → NLB (internal deployments), or external DNS → NLB (public).
2. **Obtain a cert for that name.** In order of preference:
   - Public CA (ACM, Let's Encrypt) if the name is publicly resolvable — Lambda needs no CA bundle (uses system trust store).
   - ACM Private CA — Lambda bundles the PCA root.
   - Self-signed — lowest friction for internal-only workloads; Lambda bundles the leaf as its own CA.
3. **Push cert + private key to Secrets Manager** as the JSON shape above.
4. **Deploy in a single pass** with both parameters set:
   ```
   BoltAdvertisedDNS=neo4j.example.com
   BoltCertificateSecretArn=arn:aws:secretsmanager:...:neo4j-bolt-tls
   ```
   `server.bolt.advertised_address`, the cert SAN, and the client connect URL all resolve to `neo4j.example.com` — self-consistent under EE cluster routing, and rotation does not require re-issuing against a changing NLB DNS.
5. **Rotation.** Rotate the Secrets Manager secret value, then trigger an ASG instance refresh to pick up the new cert. A Lambda or client redeploy is only needed when the trusted CA bundle changes (not on a leaf-cert rotation under the same CA).

**Cert expiry monitoring.** Phase 1 ships no cert-expiry alarm. For production, recommended options:
- AWS Config rule [`acm-certificate-expiration-check`](https://docs.aws.amazon.com/config/latest/developerguide/acm-certificate-expiration-check.html) when using ACM-issued certs.
- A CloudWatch scheduled Lambda that runs `openssl x509 -checkend` against the secret's PEM and emits a metric on days-to-expiry.
- For ACM Private CA: subscribe to the ACM PCA expiration EventBridge events.

Pick one before relying on Phase 1 in production.

### Residual risk — cluster replication traffic

Phase 1 secures only the client-facing Bolt port. Cluster-internal traffic (ports 6000 discovery, 7000 Raft, 7688 routing) remains plaintext, protected by the cluster security group alone. An actor with any of the following can still observe replication traffic on the wire:

- `ec2:RunInstances` permission to launch an instance into the cluster subnet with the cluster security group attached.
- `ec2:CreateTrafficMirrorSession` targeting a cluster ENI.
- Root on any cluster node.

If your threat model includes any of these vectors — for example, regulated workloads or shared-tenancy AWS accounts where IAM blast radius is wider than the cluster operator team — request **Phase 2 (cluster TLS)** before deploying. Phase 2 work is documented in `worklog/old_worklog/lambda-neo4j.md` §Phase 2 and requires dual-EKU certs (`serverAuth` + `clientAuth`), per-node SAN coverage, `client_auth=REQUIRE` mutual auth, and a rotation design that tolerates dual-trust during transition.

## Files

| File | Purpose |
|---|---|
| `neo4j.template.yaml` | CloudFormation template |
| `deploy.sh` | Deploy helper — creates stack, waits, writes outputs to `.deploy/` |
| `teardown.sh` | Deletes the stack, SSM parameter, copied AMI, and deployment file |
| `test-observability.sh` | Automated observability checks (CloudWatch, logs, flow logs, alarm, CloudTrail) |
| `TESTING_V2.md` | Testing guide for network hardening and security configuration verification |
| `security.md` | Security analysis, known gaps, and phased remediation plan |
| `marketplace/` | AMI build and test scripts, Marketplace publishing instructions |
| `marketplace/create-ami.sh` | Automated AMI build — launches instance, runs hardening, creates AMI, writes ID to `ami-id.txt` |
| `marketplace/test-ami.sh` | SSM-based AMI verification — checks SSH hardening and OS (no SSH key required) |
| `marketplace/build.sh` | Hardening script run on the instance (also embedded in `create-ami.sh` UserData) |
| `marketplace/ami-id.txt` | AMI ID from last build (gitignored) |
| `.deploy/` | Deployment output files — one per stack (gitignored) |

## Why the operator bastion exists — NLB hairpin

Private mode includes two design choices that look redundant at first glance but together solve one specific AWS networking pitfall that otherwise makes operator access unreliable on any private NLB deployment:

1. `preserve_client_ip.enabled=false` on both NLB target groups (`Neo4jHTTPTargetGroup`, `Neo4jBoltTargetGroup`).
2. A dedicated `t4g.nano` operator bastion that is **not** registered as an NLB target.

### What happened

While stress-testing SSM port-forward access to a three-node Private cluster, the test suite showed a non-deterministic failure pattern on an otherwise healthy stack:

- HTTP request 1 → `200 OK` in 0.1 s.
- HTTP request 2 (same tunnel) → `read timeout` after 10 s.
- Bolt handshake → TCP accept, zero bytes returned, driver deadline exceeded.

NLB target health was fine. VPC endpoints, security groups, and routing all verified. The failure rate was roughly 1 in 3 per new TCP flow.

### Root cause — NLB NAT-loopback (hairpinning) with client IP preservation enabled

AWS Network Load Balancer target groups that register targets by instance ID default to `preserve_client_ip.enabled=true`. With preservation on, the target sees the **original client's IP** as the packet source rather than the NLB's private ENI IP.

The original test setup opened its SSM tunnel through one of the Neo4j cluster members. That meant every test flow:

1. Entered the SSM Agent on that cluster member (call it node X).
2. Was proxied outward by the agent as a fresh TCP flow to `<nlb-dns>:7474|7687`. Source IP = X's private IP.
3. Hit the NLB, which flow-hashed across the three registered targets.
4. When the hash picked X itself (1 in 3), the target received a packet with **source IP == its own IP**. The host kernel treats that as invalid and silently drops the reply, so the TCP connection accepts but no data ever flows — exactly the observed "reads time out after a handshake succeeds" symptom.

AWS documents this precise failure mode:

> NAT loopback, also known as hairpinning, is not supported when client IP preservation is enabled. This occurs when using internal Network Load Balancers, and the target registered behind a Network Load Balancer creates connections to the same Network Load Balancer. The connection can be routed to the target which is attempting to create the connection, leading to connection errors.

— [AWS: Edit target group attributes — Client IP preservation](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html#client-ip-preservation)

### Why a non-target bastion fixes hairpin (short version)

Hairpin requires a single specific coincidence: **the TCP flow originates on an instance that is also one of the NLB's targets.** Only then can the NLB flow-hash select the origin as a destination, producing `src_ip == dst_ip` on that instance's NIC.

The bastion is deliberately **not** registered in any target group on the NLB. The NLB's flow-hash pool therefore never includes the bastion's IP. For every tunnelled flow:

- Source IP = bastion's private IP (e.g. `10.0.10.42`).
- Destination IP = one of the three cluster members' IPs (always different from the bastion's).
- `src_ip != dst_ip` — on every flow, by construction.

Hairpin cannot happen. Client IP preservation can even be left enabled and the tunnel would still work, because preservation only fails when src and dst collide.

### Two-layer defence

| Layer | Protects against | Mechanism |
|---|---|---|
| `preserve_client_ip.enabled=false` on target groups | Any future operator bastion that is itself an NLB target (misconfiguration, alternate bastion patterns, same-node admin tooling) | Target sees NLB ENI IP as the source; `src == dst` collision can't occur even if origin and target happen to be the same instance |
| Dedicated non-target bastion | The specific hairpin topology triggered by tunnelling through a cluster member | Origin IP is structurally outside the target pool |

Either mitigation alone would close the failure mode observed in testing. Shipping both is defence in depth: the template stays correct under future changes to either the target-group attributes or the operator-access pattern.

### Trade-off recorded with this choice

With client IP preservation disabled, `security.log` on Neo4j instances will show the NLB's private ENI IP as the connection source rather than the real operator IP. For a private marketplace deployment — where the NLB is always internal and real clients reach the stack via VPC peering, VPN, or PrivateLink — per-client attribution at the Neo4j layer is already obscured by the NLB, so this is an acceptable trade-off. Customers needing the true peer IP at the application layer can retrieve it via NLB Proxy Protocol v2.

### Alternatives considered and rejected

Two other approaches could close the same failure mode. Both were evaluated and rejected for the reasons below.

#### Alternative A — `preserve_client_ip.enabled=false` alone, skip the bastion

Disabling client IP preservation by itself does close the hairpin: the target kernel sees the NLB ENI's IP as source, never its own, so `src_ip != dst_ip` on every flow. The template's existing `Neo4jVPCFlowLog` (covering the whole VPC, including the NLB ENIs) would still provide client-IP attribution via flow logs.

**Rejected because:** the bastion adds three things the marketplace experience benefits from, all for ~$3/mo:

- **Operator UX.** The stack outputs include a ready-to-copy `aws ssm start-session` command with the bastion ID already embedded. Without the bastion, the first-time operator has to derive an `INSTANCE_ID` from the Auto Scaling Group before they can open a tunnel.
- **Test determinism.** The test suite needs a stable SSM target. The bastion is not part of the ASG, so resilience tests that terminate cluster members cannot accidentally terminate the tunnel target.
- **Defence in depth.** If a future template edit flips `preserve_client_ip.enabled` back to `true` (accidental merge, new target group, copy-paste), the bastion topology still prevents hairpin by construction because the bastion is not in any target group. Two independent layers is cheaper than rediscovering the failure mode later.

None of the three is a bug fix on top of Alternative A — they're operator ergonomics and robustness. Reasonable to skip for a hand-managed internal stack; kept for the marketplace listing where the first deploy is often the demo.

#### Alternative B — Sidecar proxy (HAProxy/Nginx) with Proxy Protocol v2 on each Neo4j node

The classical pattern: enable `proxy_protocol_v2.enabled=true` on the target groups, run a TCP-mode proxy on each Neo4j instance listening on an alternate port, have the proxy consume the PPv2 header (logging the real client IP) and forward clean traffic to Neo4j on `localhost:7687`.

**Rejected on two grounds:**

1. **PPv2 does not fix hairpin on its own.** PPv2 is an application-layer metadata header that arrives as the first bytes of the TCP stream. Hairpin is a kernel-layer `src_ip == dst_ip` drop that happens *before* any application bytes are read. The sidecar pattern only avoids hairpin because you would also disable client IP preservation — at which point the hairpin is already gone and the sidecar is buying only the per-instance client-IP log.

2. **Per-node proxy is a lot of moving parts for a marketplace AMI.** Adding HAProxy or Nginx means: install and configure the proxy in UserData (already ~150 lines of bash for Neo4j itself), a systemd unit plus health checks plus log rotation, another failure domain per node (proxy crash = Bolt down on that node), a TCP-mode PPv2 config that differs from the HTTP PPv2 most operators have seen, and a second log stream to correlate with Neo4j's own auth log since Neo4j itself would see every connection as `127.0.0.1`. VPC flow logs (already provisioned) give the same audit trail with zero per-instance code.

### References

- [AWS: Edit target group attributes — Client IP preservation](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html#client-ip-preservation)
- [AWS: Troubleshoot your Network Load Balancer — Connections time out for requests from a target to its load balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-troubleshooting.html)
- Internal worklog: [`neo4j-ee/worklog/FIX_SSM_V7.md`](worklog/FIX_SSM_V7.md) §9-§11 for the full investigation and fix rationale.
