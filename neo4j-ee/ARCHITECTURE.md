# Neo4j EE Architecture

This document covers the network topology the CloudFormation template creates, the design decisions behind NLB routing and Bolt TLS, and the specific AWS networking pitfall that required a dedicated operator bastion.

---

## Deployment Modes

Three separate templates cover the supported topologies: private (new VPC), public (new VPC), and private with an existing VPC.

| Setting | Private (default) | Public |
|---|---|---|
| Instance placement | Private subnets, no public IP | Public subnets, public IP assigned |
| NLB type | Internal — routable from inside the VPC only | Internet-facing |
| Outbound internet | Via NAT Gateways | Via Internet Gateway |
| Operator access | SSM Session Manager port-forwarding | Direct TCP |
| Use case | Production, regulated workloads | Development, demos |

---

## Network Topology

### Private Mode — Three-Node Cluster

- VPC with three public subnets (one per AZ) hosting NAT Gateways, and three private subnets (one per AZ) hosting the Neo4j instances
- Internal NLB with listeners on ports 7474 (HTTP) and 7687 (Bolt), targets distributed across all three private subnets
- Three Neo4j EC2 instances in private subnets forming a Raft cluster
- Three NAT Gateways for outbound traffic from the cluster members
- One `t4g.nano` operator bastion in a private subnet, not registered as an NLB target
- VPC interface endpoints for `ssm`, `ssmmessages`, `logs`, and `secretsmanager` with `PrivateDnsEnabled: true`
- External security group: inbound on 7474 and 7687 from `AllowedCIDR`
- Internal security group: cluster ports 5000, 6000, 7000, 7688 restricted to cluster members only

### Private Mode — Single Instance

- VPC with one public subnet (NAT Gateway) and one private subnet (EC2 instance)
- Internal NLB in the private subnet
- One NAT Gateway for outbound traffic
- One EC2 instance in the private subnet
- One `t4g.nano` operator bastion in the private subnet

### Public Mode — Three-Node Cluster

- VPC with three public subnets, one per AZ
- Internet-facing NLB across all three subnets
- Three EC2 instances with public IPs forming a Raft cluster; no NAT Gateways needed
- External security group: inbound on 7474 and 7687 from `AllowedCIDR`
- Internal security group: cluster ports restricted to cluster members only

### Public Mode — Single Instance

- VPC with a single public subnet
- Internet-facing NLB in that subnet
- One EC2 instance with a public IP

### Security Configuration

| Setting | Default | Notes |
|---|---|---|
| `AllowedCIDR` | required | CIDR allowed to reach ports 7474 and 7687. Private mode: `10.0.0.0/16`. Public mode: the client CIDR. `0.0.0.0/0` is rejected. |
| IMDSv2 | enforced | Instance metadata requires session tokens; IMDSv1 requests are rejected. |
| JDWP (port 5005) | disabled | Remote debug port is closed and the JVM debug flag is stripped from `neo4j.conf` at boot. |
| Cluster ports | self-referencing SG | Ports 5000, 6000, 7000, 7688 reachable only from other cluster members. |

---

## NLB Routing and URI Scheme

### How the Template Configures Routing

At boot, each cluster node sets two `neo4j.conf` values:

```
server.bolt.advertised_address = <nlb-dns>:7687
dbms.routing.default_router    = SERVER
```

`server.bolt.advertised_address` controls the address a node advertises in routing tables. Setting it to the NLB DNS rather than the node's own private IP means every routing table entry points back to the NLB. `dbms.routing.default_router=SERVER` tells the node to return a one-entry routing table (the NLB) rather than the full list of cluster member IPs. A driver connecting with `neo4j://` receives a routing table containing only the NLB DNS, sends all subsequent requests through it, and lets Neo4j server-side routing handle write-versus-read direction.

### URI Scheme by Access Pattern

| Access pattern | URI | Notes |
|---|---|---|
| Same VPC | `neo4j://<nlb-dns>:7687` | Routing table returns NLB DNS; driver stays on NLB; full cluster failover |
| Peered VPC / Transit Gateway | `neo4j://<nlb-dns>:7687` | NLB DNS resolves to private IPs reachable through the peering route |
| SSM tunnel | `bolt://localhost:7687` | Skips routing table; reliable for operator access |
| SSM tunnel + routing scheme | `neo4j://localhost:7687` with custom resolver | Routing table returns NLB DNS, which resolves to private IPs not reachable from the laptop; fails without a custom resolver |
| Direct node IP (same subnet) | `bolt://<node-ip>:7687` | Bypasses NLB; single node, no failover |

### `neo4j://` Through an SSM Tunnel Requires a Custom Resolver

Via SSM, the driver connects to `localhost:7687`. The server returns a routing table with the NLB DNS name. The driver then tries to open new connections to that address, which resolves to private IPs inside the VPC — not routable from the operator's laptop. The simplest fix is `bolt://localhost:7687` for SSM access. If `neo4j://` is required (for example, a CI runner that must exercise cluster routing), use a custom resolver that maps the NLB DNS back to `localhost`:

```python
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

**References:** [Leadership, routing, and load balancing](https://neo4j.com/docs/operations-manual/current/clustering/setup/routing/) · [Configure network connectors](https://neo4j.com/docs/operations-manual/current/configuration/connectors/)

---

## Password Secret Format

The Neo4j admin password is stored in Secrets Manager as a **plain string** — the password value itself, not JSON. Consumers retrieve it with:

```
aws secretsmanager get-secret-value \
  --secret-id <password-secret-arn> \
  --query SecretString --output text
```

and pass the result directly as `NEO4J_PASSWORD`. The ARN is published at `/neo4j-ee/<stack>/password-secret-arn` and surfaced in the deploy-outputs file as `Neo4jPasswordSecretArn`.

The Bolt TLS secret (when `--tls` is set) follows a different convention: a JSON object with `certificate` and `private_key` keys. See [TLS on Bolt → Secret Format](#secret-format) below.

---

## TLS on Bolt

The template provisions TLS on the Bolt connector from a customer-supplied certificate. When `BoltCertificateSecretArn` is set, Neo4j is configured with `server.bolt.tls_level=REQUIRED` against the cert and key in the named Secrets Manager secret. When empty (the default), Bolt runs as plain TCP — appropriate for internal-only deployments where the VPC and security group boundary is the trust boundary.

Phase 1 covers Bolt only. The HTTP browser endpoint (7474) and cluster-internal ports (6000/7000/7688) remain plaintext.

### Secret Format

Create a single Secrets Manager secret whose `SecretString` is JSON:

```json
{
  "certificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n",
  "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
}
```

Both fields are required. UserData validates the JSON shape on boot and fails the stack with a clear error if either field is missing.

### Production Guidance — Customer-Owned DNS

The recommended production pattern uses a stable customer-owned DNS name in front of the NLB so certificates are not pinned to the AWS-generated NLB DNS:

1. Create a Route53 private hosted zone with an A-record alias pointing to the NLB (internal deployments), or configure external DNS pointing to the NLB (public).
2. Obtain a certificate for that name. In order of preference: public CA (ACM, Let's Encrypt) if the name is publicly resolvable; ACM Private CA; self-signed for internal-only workloads.
3. Push the cert and private key to Secrets Manager using the JSON format above.
4. Deploy with both parameters set:
   ```
   BoltAdvertisedDNS=neo4j.example.com
   BoltCertificateSecretArn=arn:aws:secretsmanager:...:neo4j-bolt-tls
   ```
   `server.bolt.advertised_address`, the cert SAN, and the client connect URL all resolve to `neo4j.example.com` — self-consistent under EE cluster routing, and cert rotation does not require re-issuing against a changing NLB DNS.
5. To rotate, update the Secrets Manager secret value, then trigger an ASG instance refresh to pick up the new cert.

**Cert expiry monitoring.** Phase 1 ships no cert-expiry alarm. For production: use the AWS Config rule `acm-certificate-expiration-check` for ACM-issued certs, or a CloudWatch scheduled Lambda that runs `openssl x509 -checkend` against the secret's PEM and emits a days-to-expiry metric.

### Residual Risk — Cluster Replication Traffic

Phase 1 secures only the client-facing Bolt port. Cluster-internal traffic (ports 6000 discovery, 7000 Raft, 7688 routing) remains plaintext, protected by the cluster security group alone. An actor with `ec2:RunInstances` permission to launch an instance into the cluster subnet with the cluster security group, `ec2:CreateTrafficMirrorSession` targeting a cluster ENI, or root on any cluster node can still observe replication traffic on the wire.

If your threat model includes any of these vectors — regulated workloads or shared-tenancy AWS accounts where IAM blast radius extends beyond the cluster operator team — request Phase 2 (cluster TLS) before deploying. Phase 2 requires dual-EKU certs (`serverAuth` + `clientAuth`), per-node SAN coverage, `client_auth=REQUIRE` mutual auth, and a rotation design that tolerates dual-trust during transition.

---

## Operator Bastion — NLB Hairpin

Private mode includes two choices that address a specific AWS networking failure mode: `preserve_client_ip.enabled=false` on both NLB target groups, and a dedicated `t4g.nano` bastion that is not registered as an NLB target.

### The Failure Mode

While stress-testing SSM port-forward access to a three-node Private cluster, the test suite showed a non-deterministic failure pattern on an otherwise healthy stack:

- HTTP request 1 → `200 OK` in 0.1 s.
- HTTP request 2 (same tunnel) → `read timeout` after 10 s.
- Bolt handshake → TCP accept, zero bytes returned, driver deadline exceeded.

NLB target health was fine. VPC endpoints, security groups, and routing all verified. The failure rate was roughly 1 in 3 per new TCP flow.

### Root Cause

AWS NLB target groups that register targets by instance ID default to `preserve_client_ip.enabled=true`. With preservation on, the target sees the original client's IP as the packet source rather than the NLB's private ENI IP.

The original test setup tunnelled SSM through one of the Neo4j cluster members (call it node X). Every test flow:

1. Entered the SSM Agent on node X.
2. Was proxied outward as a fresh TCP flow to `<nlb-dns>:7474|7687`. Source IP = X's private IP.
3. Hit the NLB, which flow-hashed across the three registered targets.
4. When the hash picked X itself (1 in 3), the target received a packet with source IP equal to its own IP. The host kernel treats that as invalid and silently drops the reply — exactly the "reads time out after a handshake succeeds" symptom.

AWS documents this failure mode explicitly:

> NAT loopback, also known as hairpinning, is not supported when client IP preservation is enabled. This occurs when using internal Network Load Balancers, and the target registered behind a Network Load Balancer creates connections to the same Network Load Balancer. The connection can be routed to the target which is attempting to create the connection, leading to connection errors.

— [AWS: Edit target group attributes — Client IP preservation](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html#client-ip-preservation)

### Why a Non-Target Bastion Fixes the Problem

Hairpin requires a specific coincidence: the TCP flow originates on an instance that is also one of the NLB's registered targets. Only then can the NLB flow-hash select the origin as a destination, producing `src_ip == dst_ip` on that instance's NIC.

The bastion is not registered in any target group. The NLB's flow-hash pool never includes the bastion's IP. For every tunnelled flow, the source IP is the bastion's private IP and the destination IP is one of the three cluster members' IPs — always different. Hairpin cannot happen by construction.

### Two-Layer Defence

The template ships both mitigations:

| Layer | Protects against | Mechanism |
|---|---|---|
| `preserve_client_ip.enabled=false` on target groups | Any future case where the origin happens to be an NLB target (misconfiguration, alternate bastion patterns) | Target sees NLB ENI IP as source; `src == dst` collision is structurally impossible |
| Dedicated non-target bastion | The hairpin topology triggered by tunnelling through a cluster member | Origin IP is outside the target pool by design |

Either mitigation alone closes the observed failure. Shipping both means the template stays correct if a future edit changes either the target-group attributes or the operator-access pattern.

**Trade-off.** With client IP preservation disabled, `security.log` on Neo4j instances records the NLB's private ENI IP as the connection source rather than the real operator IP. For a private deployment where the NLB is always internal, per-client attribution at the Neo4j layer is already obscured by the NLB; this is an acceptable trade-off. Customers needing the true peer IP at the application layer can retrieve it via NLB Proxy Protocol v2.

### Alternatives Considered

**`preserve_client_ip.enabled=false` alone, no bastion.** Disabling client IP preservation closes the hairpin — the target kernel sees the NLB ENI's IP as source, never its own. Rejected because the bastion adds three things the marketplace experience benefits from: a ready-to-copy `aws ssm start-session` command in the stack outputs; a stable SSM target that resilience tests cannot accidentally terminate (the bastion is not in the ASG); and defence in depth if a future template edit re-enables client IP preservation.

**Sidecar proxy (HAProxy/Nginx) with Proxy Protocol v2 on each Neo4j node.** PPv2 is an application-layer header that arrives after the TCP handshake. Hairpin is a kernel-layer drop that happens before any application bytes are read — PPv2 does not fix hairpin on its own. Combining PPv2 with disabled client IP preservation would close the hairpin (same as the current fix), but adds HAProxy or Nginx to every node: installation in UserData, a systemd unit with health checks and log rotation, a separate failure domain per node, and a second log stream to correlate with Neo4j's auth log. VPC flow logs (already provisioned) provide the same audit trail with zero per-instance code.

**References:**
- [AWS: Edit target group attributes — Client IP preservation](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/edit-target-group-attributes.html#client-ip-preservation)
- [AWS: Troubleshoot your Network Load Balancer — Connections time out](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/load-balancer-troubleshooting.html)
- Internal worklog: [`worklog/old_worklog/FIX_SSM_V7.md`](worklog/old_worklog/FIX_SSM_V7.md) §9–§11
