# Neo4j EE: Private

`neo4j-private.template.yaml` deploys a Neo4j Enterprise cluster in private subnets behind an internal Network Load Balancer.

- **What it deploys:** Neo4j EE cluster (1 or 3 nodes) in private subnets behind an internal NLB
- **Public exposure:** none — no instance has a public IP
- **Operator access:** dedicated `t4g.nano` bastion via AWS Systems Manager Session Manager
- **When to use:** production, staging, and regulated workloads

> **Marketplace operator** (deployed from AWS Marketplace, running stack):
> Start with [Prerequisites](#prerequisites) and the [Operator Guide](#operator-guide) below.
>
> **Template developer** (working on the templates, deploying from source):
> Start with [Local Deployment and Testing](#local-deployment-and-testing).
> The [Operator Guide](#operator-guide) applies once your stack is running.

## Contents

- [Operator Guide](#operator-guide)
  - [Prerequisites](#prerequisites)
  - [Preflight Check](#preflight-check)
  - [Access via Bastion](#access-via-bastion)
  - [Bolt Tunnel](#bolt-tunnel)
  - [Browser Tunnel](#browser-tunnel)
  - [Retrieve the Password](#retrieve-the-password)
  - [Admin Shell](#admin-shell)
  - [Ad-Hoc Cypher Queries](#ad-hoc-cypher-queries)
  - [Observability](#observability)
- [Architecture](#architecture)
  - [Network Topology](#network-topology)
  - [AWS Resources Created](#aws-resources-created)
  - [NLB Routing](#nlb-routing)
  - [Operator Bastion: NLB Hairpin](#operator-bastion-nlb-hairpin)
  - [Platform Contract](#platform-contract)
  - [Password Security Model](#password-security-model)
  - [TLS Architecture](#tls-architecture)
- [Local Deployment and Testing](#local-deployment-and-testing)
  - [Set Up a Certificate](#set-up-a-certificate)
  - [Build](#build)
  - [Deploy](#deploy)
  - [Local Dry Run](#local-dry-run)
  - [Preflight and Basic Validation](#preflight-and-basic-validation)
  - [Smoke Test](#smoke-test)
  - [Failover Suite](#failover-suite)
  - [Resilience Suite](#resilience-suite)
  - [Tear Down](#tear-down)
  - [Troubleshooting](#troubleshooting)

---

## Operator Guide

Applies to any running private stack, whether deployed from the Marketplace or from source.

All `uv run` commands (`admin-shell`, `run-cypher`, `validate-private`) must be run from `neo4j-ee/validate-private/`. Shell scripts under `scripts/` must be run from `neo4j-ee/validate-private/` as well.

### Prerequisites

**AWS tooling**

```bash
aws --version                                    # AWS CLI v2
brew install --cask session-manager-plugin       # required for SSM port-forward tunnels
session-manager-plugin --version
```

**Python tooling**

```bash
python3 --version   # 3.11+
brew install uv     # package manager for validate-private and test suite
```

**IAM permissions**

These are the minimum permissions the operator's local IAM principal (user or assumed role) needs to run the tools in this guide. Each permission corresponds to API calls made from the operator's machine. The cluster nodes use a separate IAM role scoped to what they need at boot.

| Permission | Resource | Used by |
|---|---|---|
| `cloudformation:DescribeStacks`, `cloudformation:DescribeStackResources` | The stack ARN | `uv run preflight`, `deploy.py` (reads stack outputs) |
| `ssm:SendCommand`, `ssm:GetCommandInvocation`, `ssm:StartSession`, `ssm:DescribeInstanceInformation` | The bastion instance | `uv run scripts/browser-tunnel.py`, `uv run scripts/bolt-tunnel.py`, `admin-shell`, `run-cypher`, `validate-private`, `uv run preflight` (bastion ping check) |
| `ssm:GetParameter`, `ssm:GetParametersByPath` | `/neo4j-ee/<stack-name>/*` | Any tool that resolves the NLB DNS or security group IDs from the platform contract |
| `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` | `neo4j/<stack-name>/password` | `get-password.sh`, `uv run preflight` (secret existence check) |

### Preflight Check

Before running any other tool, confirm the stack and bastion are ready:

```bash
cd neo4j-ee/validate-private
uv run preflight                     # most recent deployment
uv run preflight <stack-name>        # specific deployment
```

Expected output on a healthy stack:

```
=== Preflight Checks ===

  Stack:   test-ee-1776575131
  Region:  us-east-1
  Bastion: i-0abc123def456789

  [PASS] Stack status = CREATE_COMPLETE
  [PASS] Bastion SSM PingStatus = Online
  [PASS] neo4j Python driver installed on bastion
  [PASS] cypher-shell installed on bastion
  [PASS] Secret 'neo4j/test-ee-1776575131/password' exists
  [PASS] Contract SSM params: vpc-id, nlb-dns, advertised-dns, external-sg-id, password-secret-arn, vpc-endpoint-sg-id
  [INFO] Operational SSM params: region, stack-name, private-subnet-1-id, private-subnet-2-id
  [PASS] VPC interface endpoints: secretsmanager, logs, ssm, ssmmessages
  [PASS] Endpoint reachable: secretsmanager.us-east-1.amazonaws.com
  [PASS] Endpoint reachable: logs.us-east-1.amazonaws.com
  [PASS] Endpoint reachable: ssm.us-east-1.amazonaws.com
  [PASS] Endpoint reachable: ssmmessages.us-east-1.amazonaws.com

  11 passed, 0 failed
```

If the bastion SSM check fails immediately after a fresh deploy, the bastion UserData may still be running. Wait 2-3 minutes and retry.

### Access via Bastion

All operator access goes through the `t4g.nano` bastion via SSM. Tunnels are only needed when your laptop talks to the NLB directly. Run `uv run` commands from `neo4j-ee/validate-private/`.

`CreatePrivateDns=true` makes `AdvertisedDNS` resolve inside the VPC, so bastion-run tools such as `admin-shell`, `run-cypher`, `validate-private`, and `uv run scripts/smoke-write.py` need no local DNS changes. It does not change your laptop resolver. For local SSM port-forward tunnels, keep the `/etc/hosts` entry so `AdvertisedDNS` resolves to `127.0.0.1` and the connection still uses the certificate name rather than `localhost`.

| Tool | How it connects | Tunnel needed? |
|---|---|---|
| `uv run admin-shell` | SSM interactive session on the bastion | No |
| `uv run run-cypher` | SSM `RunShellScript` on the bastion | No |
| `uv run validate-private` | SSM `RunShellScript` on the bastion | No |
| `uv run scripts/smoke-write.py` | SSM `RunShellScript` on the bastion | No |
| Local driver or client tool | Bolt connection from your laptop | Yes — Bolt tunnel (7687) |
| Neo4j Browser | HTTPS for the web UI + Bolt for queries | Yes — both tunnels (7473 + 7687) |

### Bolt Tunnel

Use the Bolt tunnel when you want to connect a local driver, client tool, or script to the cluster from your laptop.

```bash
uv run scripts/bolt-tunnel.py      # localhost:7687 -> NLB:7687  (blocks; Ctrl-C to close)
```

- **Connect URL:** use the URI printed by `uv run scripts/bolt-tunnel.py`. It chooses `bolt` for single-server stacks, `neo4j` for clusters, `+s` for system-trusted certificates, and `+ssc` for self-signed/imported/private certificates that are not installed in the client trust store.
- **Required hosts entry for laptop tunnels:** `127.0.0.1 <AdvertisedDNS>` in `/etc/hosts` — the NLB-presented certificate is issued for `AdvertisedDNS`, so connecting to `localhost` fails hostname validation for trusted certs. Stack-managed private DNS helps clients inside the VPC; it does not affect local laptop DNS.
- **Bypass routing table:** use `bolt+s://` instead of `neo4j+s://`, or `bolt+ssc://` instead of `neo4j+ssc://` for self-signed tests. With `neo4j+s://` or `neo4j+ssc://`, the routing table contains `AdvertisedDNS` itself, which resolves back to `localhost` via the hosts entry and works through the same tunnel
- **Also required for Neo4j Browser:** open this tunnel alongside the [Browser Tunnel](#browser-tunnel)

### Browser Tunnel

Use this to open the Neo4j Browser web UI. The browser makes two connections: HTTPS to load the UI (port 7473) and Bolt to run queries (port 7687). Both tunnels must be open simultaneously.

**Single-command option** — run from `neo4j-ee/`:

```bash
uv run browse.py                   # most recent deployment
uv run browse.py <stack-name>      # specific deployment
```

`browse.py` reads `.deploy/<stack-name>.txt`, opens both SSM port-forward tunnels in the same shell (7473 and 7687), and prints the URL and credentials. Press Ctrl+C to close both tunnels.

**Two-terminal option** — run from `neo4j-ee/validate-private/`:

```bash
uv run scripts/browser-tunnel.py   # localhost:7473 -> NLB:7473  (blocks; Ctrl-C to close)
uv run scripts/bolt-tunnel.py      # localhost:7687 -> NLB:7687  (blocks; Ctrl-C to close)
```

Add `127.0.0.1 <AdvertisedDNS>` to your laptop's `/etc/hosts`, then open `https://<AdvertisedDNS>:7473`. When prompted for a connection URL, enter the Bolt URI printed by `uv run browse.py` or `uv run scripts/bolt-tunnel.py`. For the password, see [Retrieve the Password](#retrieve-the-password).

For self-signed test certificates, the browser will still show a certificate warning for `https://<AdvertisedDNS>:7473`; that is expected for local testing. Marketplace/customer deployments should use a certificate trusted by the client.

> **Note:** Connection strings inside Neo4j Browser show `AdvertisedDNS`, which now resolves to `127.0.0.1` for the duration of the tunnel session. Remove the hosts entry when finished.

> **Note:** Writes through Neo4j Browser go to whichever node the NLB selects, which may not be the leader, producing a `NotALeader` error. Use `uv run admin-shell` for writes.

### Retrieve the Password

```bash
./scripts/get-password.sh

# To capture it:
PASSWORD=$(./scripts/get-password.sh 2>/dev/null)
```

The password is stored in Secrets Manager at `neo4j/<stack-name>/password` as a plain string: the password value itself, not JSON.

Only the Browser Tunnel requires the password locally — you type it into the Neo4j Browser login form. `admin-shell` and `run-cypher` resolve the password on the bastion using the bastion's IAM role; it never appears on your local machine or in CloudTrail.

### Admin Shell

For Cypher queries and write operations:

```bash
cd neo4j-ee/validate-private
uv run admin-shell                     # most recent deployment
uv run admin-shell <stack-name>        # specific deployment
```

Opens `cypher-shell` on the bastion with `neo4j+s://<AdvertisedDNS>:7687` for trusted certificates, or `neo4j+ssc://<AdvertisedDNS>:7687` when the EE output file has `SelfSignedCertificate=true`. The Neo4j driver fetches the routing table and directs writes to the current leader automatically. The password is resolved on the bastion using the bastion's IAM role. It does not appear on the local machine or in CloudTrail.

```
neo4j@neo4j> CREATE (n:Test {msg: "hello"}) RETURN n;
neo4j@neo4j> MATCH (n:Test) DELETE n;
neo4j@neo4j> :exit
```

### Ad-Hoc Cypher Queries

```bash
cd neo4j-ee/validate-private
uv run run-cypher "CALL dbms.components() YIELD name, versions, edition RETURN name, versions[0] AS version, edition"

# Output is JSON; pipe to jq for formatting
uv run run-cypher "SHOW SERVERS YIELD name, address, state, health" | jq .

# Target a specific stack
uv run run-cypher <stack-name> "MATCH (n) RETURN count(n) AS total"
```

### Observability

```bash
cd neo4j-ee
./test-observability.sh                  # most recent deployment
./test-observability.sh <stack-name>     # specific deployment
```

| Step | What it checks | Typical duration |
|---|---|---|
| `cloudwatch` | CloudWatch agent active on all nodes | <1 min |
| `logs` | Application log group exists with expected stream count | <1 min |
| `flowlogs` | VPC flow log group exists and has ENI streams | <1 min |
| `alarm` | Failed-auth alarm transitions to ALARM after 12 bad login attempts | ~7 min |
| `cloudtrail` | A multi-region CloudTrail trail exists and is logging | <1 min |

---

## Architecture

![Neo4j EE Private Architecture](images/neo4j-private-architecture.png)

### Network Topology

**Three-node cluster:**
- VPC with three public subnets (one per AZ) hosting NAT Gateways, and three private subnets (one per AZ) hosting the Neo4j instances
- Internal NLB with TLS listeners on 7473 (HTTPS) and 7687 (Bolt), with encrypted client-to-NLB and NLB-to-instance hops via TLS target groups, targets spread across all three private subnets
- Three Neo4j EC2 instances in private subnets, forming a Raft cluster
- Three NAT Gateways for outbound traffic from the cluster members
- One `t4g.nano` operator bastion in a private subnet, not registered as an NLB target
- VPC interface endpoints for `ssm`, `ssmmessages`, `logs`, and `secretsmanager` with `PrivateDnsEnabled: true`

**Single instance:**
- VPC with one public subnet (NAT Gateway) and one private subnet (EC2 instance)
- Internal NLB in the private subnet
- One NAT Gateway
- One `t4g.nano` operator bastion

### AWS Resources Created

| AWS Resource | What it creates |
|---|---|
| VPC | New VPC with public subnets (NAT Gateways) and private subnets (Neo4j instances); 3 AZs for a cluster, 1 AZ for a single instance |
| NAT Gateways | One per AZ for outbound internet access from the cluster nodes |
| Internal NLB | Listeners on port 7473 (HTTPS) and 7687 (Bolt); routable from inside the VPC only |
| EC2 instances | 1 or 3 Neo4j nodes in private subnets; no public IPs |
| ASG per node | One Auto Scaling Group per Neo4j node, fixed at `MinSize=MaxSize=DesiredCapacity=1`, for self-healing |
| EBS data volumes | One GP3 volume per node with `DeletionPolicy: Retain`; survives stack deletion |
| Operator bastion | `t4g.nano` in a private subnet, not registered as an NLB target; receives SSM sessions for operator access |
| VPC interface endpoints | `ssm`, `ssmmessages`, `logs`, `secretsmanager` with `PrivateDnsEnabled: true`; no NAT required for AWS service calls |
| Security groups | NLB SG (AllowedCIDR on 7473/7687 to the NLB); External SG (NLB SG as source on 7473/7687 to instances); Internal SG (cluster ports 5000/6000/7000/7688 between members only); Endpoint SG (gating access to the VPC endpoints) |
| SSM parameters | `/neo4j-ee/<stack>/` prefix; publishes VPC ID, NLB DNS, security group IDs, and secret ARN for downstream consumers |
| Secrets Manager | Neo4j admin password at `neo4j/<stack>/password` |
| CloudWatch | Log group, VPC flow logs, failed-auth alarm, CloudTrail trail |

### NLB Routing

At boot, each cluster node sets:

```
server.bolt.advertised_address  = <AdvertisedDNS>:7687
server.https.advertised_address = <AdvertisedDNS>:7473
dbms.routing.default_router     = SERVER
```

Every routing table entry points back to `AdvertisedDNS`. A driver connecting with `neo4j+s://` receives a routing table containing only `AdvertisedDNS`, sends all subsequent requests through it, and lets Neo4j server-side routing handle leader vs. follower direction. The NLB terminates client TLS on the listener using the customer-supplied ACM cert (whose SAN matches `AdvertisedDNS`) and then opens a separate encrypted TLS connection to the instance using a self-signed backend cert generated at boot.

| Access pattern | URI | Notes |
|---|---|---|
| Same VPC | `neo4j+s://<AdvertisedDNS>:7687` | Full cluster failover. `AdvertisedDNS` should normally resolve to the NLB through Route 53 private DNS. |
| Peered VPC / Transit Gateway | `neo4j+s://<AdvertisedDNS>:7687` | Same. The NLB DNS resolves to private IPs reachable through the peering route; the Route 53 record can target the NLB hostname. |
| SSM tunnel | `neo4j+s://<AdvertisedDNS>:7687`, or `neo4j+ssc://<AdvertisedDNS>:7687` for self-signed tests, with `127.0.0.1 <AdvertisedDNS>` in `/etc/hosts` | Routing table returns `AdvertisedDNS` -> loops back to the tunnel via the hosts entry. |
| Direct node IP | `neo4j+ssc://<node-ip>:7687` | Bypasses NLB; single node, no failover. `+ssc` skips cert validation since the self-signed backend cert is not bound to an IP. |

**`neo4j+s://` through an SSM tunnel relies on `/etc/hosts`.** The driver opens a TLS handshake to `<AdvertisedDNS>:7687`. The hosts entry resolves that to `127.0.0.1`, so the tunnel terminates the connection at the NLB. The NLB presents the ACM cert; the cert's SAN matches `AdvertisedDNS`, so the driver validates successfully. The server then returns a routing table containing `<AdvertisedDNS>:7687`, and the driver loops back through the same tunnel for subsequent connections. No custom Python resolver is needed.

### Operator Bastion: NLB Hairpin

> **Why a dedicated bastion?** To prevent NLB hairpin failures where a cluster node tunneling SSM through itself sees its own IP as the source and silently drops the reply — a 1-in-3 connection failure rate.

The bastion is `t4g.nano`, sits in the same private subnet as the cluster, and is not registered as an NLB target.

**The failure.** When SSM tunnels ran through a Neo4j cluster member instead of a dedicated bastion, every third connection timed out. NLB target health was fine; VPC endpoints, security groups, and routing all checked out.

**Root cause.** NLB target groups default to `preserve_client_ip.enabled=true`. With preservation on, each target sees the real source IP of incoming connections. When a cluster node tunnels an SSM session outward, the source IP of each new connection is that node's own private IP. The NLB flow-hashes across the three registered targets. When the hash selects the same node as the origin — a 1-in-3 probability — the instance receives a packet with source IP equal to its own IP. The kernel treats that as invalid and silently drops the reply.

**The fix.** Two layers ship together:

| Layer | Mechanism |
|---|---|
| `preserve_client_ip.enabled=false` on both NLB target groups | Each target sees the NLB ENI IP as the source. A `src == dst` collision is structurally impossible. |
| Dedicated non-target bastion | The bastion's IP is outside the NLB target pool. Hairpin cannot happen by construction. |

Either mitigation alone closes the observed failure. Both ship together so the template stays correct if a future edit changes the target-group attributes or the operator-access pattern.

**Trade-off.** With client IP preservation disabled, `security.log` on the Neo4j instances records the NLB's private ENI IP as the connection source, not the real operator IP. For an internal-only deployment, per-client attribution at the Neo4j layer is already obscured by the NLB, which is an acceptable trade-off. Customers requiring the true peer IP at the application layer can retrieve it via NLB Proxy Protocol v2.

### Platform Contract

The stack publishes resource IDs via SSM under `/neo4j-ee/<stack-name>/` so that applications and operator tooling can wire themselves up without knowing stack internals. `uv run preflight` validates both groups on every run.

**Contract parameters** — required; all six must exist:

| Parameter | Purpose |
|---|---|
| `/neo4j-ee/<stack>/vpc-id` | VPC the application should attach to |
| `/neo4j-ee/<stack>/nlb-dns` | Internal NLB DNS name; map `AdvertisedDNS` to this hostname for TLS clients to validate the ACM cert SAN |
| `/neo4j-ee/<stack>/advertised-dns` | DNS name that resolves to the internal NLB and matches the ACM cert SAN; clients connect via `neo4j+s://<advertised-dns>:7687` and `https://<advertised-dns>:7473` |
| `/neo4j-ee/<stack>/external-sg-id` | NLB security group that accepts client/app ingress on 7473 and 7687 |
| `/neo4j-ee/<stack>/password-secret-arn` | Secrets Manager ARN for the Neo4j password |
| `/neo4j-ee/<stack>/vpc-endpoint-sg-id` | Security group attached to the VPC interface endpoints |

**Operational parameters** — informational:

| Parameter | Purpose |
|---|---|
| `/neo4j-ee/<stack>/region` | AWS region |
| `/neo4j-ee/<stack>/stack-name` | Stack name |
| `/neo4j-ee/<stack>/private-subnet-1-id` | First private subnet |
| `/neo4j-ee/<stack>/private-subnet-2-id` | Second private subnet |
| `/neo4j-ee/<stack>/private-route-table-1-id` | Route table for the first private subnet |

**VPC interface endpoints.** The regional service hostnames (`ssm`, `ssmmessages`, `logs`, `secretsmanager`) resolve to private IPs inside the VPC. No endpoint URL overrides are needed in application code, and no NAT data-processing charges apply to AWS service calls.

The `vpc-endpoint-sg-id` parameter is the mechanism by which applications opt into reaching these endpoints. Each application adds its own security group to the endpoint SG's ingress on port 443. Opening the endpoint SG to the whole VPC CIDR would allow any workload in the VPC to call SSM and Secrets Manager via PrivateLink. The published SG ID approach requires each application to explicitly opt in, creating an auditable per-application record and a clean removal path.

See [`sample-private-app/README.md`](../sample-private-app/README.md) for the full application connection pattern.

### Password Security Model

- **Allowed characters:** `^[a-zA-Z0-9]{24,}$` — alphanumerics only, 24+ chars. Prevents shell metacharacter injection (e.g. `Test1$(cmd)` executing as root during boot)
- **Default length:** `deploy.py` generates a 32-character value
- **Storage:** Secrets Manager at `neo4j/<stack-name>/password`
- **Never in UserData:** `NoEcho: true` only suppresses values in CloudFormation API responses, not UserData. Any IAM principal with `ec2:DescribeLaunchTemplateVersions` can read UserData
- **Retrieval at boot:** cluster nodes fetch the password via their IAM role, which has `secretsmanager:GetSecretValue` scoped to the single stack secret

### TLS Architecture

**TL;DR**

- **TLS is mandatory.** The NLB terminates TLS on 7473 (HTTPS Browser) and 7687 (Bolt) using the `CertificateArn` ACM certificate
- **Encrypted on both client data-plane hops.** The NLB terminates client TLS, and target groups open a separate TLS connection to a self-signed backend cert generated on each instance at boot. This encrypts client-to-NLB and NLB-to-instance traffic without implying one uninterrupted client-to-instance TLS session
- **`AdvertisedDNS` is the TLS hostname** clients use; it must match the ACM cert SAN. Typically a Route 53 private hosted zone name like `neo4j.prod.internal.example.com`
- **No public exposure required.** The Private template does not create public DNS or ingress. Public access, API front doors, VPN, etc. are separate customer-owned layers — see [`sample-private-app/README.md`](../sample-private-app/README.md)

**Customer responsibilities at deploy time**

1. Provision or import an ACM certificate in the same Region as the stack. The certificate SAN must match the DNS name you will pass as `AdvertisedDNS`.
2. Ensure private DNS resolves `AdvertisedDNS` to the internal NLB for every in-VPC client. `deploy.py` sets `CreatePrivateDns=true` by default for Private mode, so the stack creates an A-record alias to the NLB unless you pass `--no-create-private-dns`.
3. Pass `CertificateArn` and `AdvertisedDNS` as CloudFormation parameters at stack create or update. If `CreatePrivateDns=true`, also pass either `PrivateDnsZoneName` so the stack creates a private hosted zone, or `PrivateDnsHostedZoneId` so it writes the record into an existing private hosted zone. `deploy.py` derives `PrivateDnsZoneName` from `AdvertisedDNS` when possible.

**Cert lifecycle**

- **Backend cert (NLB → instance):** generated on each node at first boot via `openssl req -x509` in `/var/lib/neo4j/certificates/{bolt,https}/`. The NLB does not validate it, so self-signed is sufficient. Regenerated on instance replacement with no client-visible effect — clients only see the NLB-presented ACM cert
- **ACM cert rotation (clients → NLB):** ACM-managed certs renew automatically. To swap ARNs, update the `CertificateArn` stack parameter — CloudFormation updates the listener in place, no instance refresh required
- **Regional scope:** ACM certs are regional. A stack deployed with `--region us-east-2` requires an ARN beginning with `arn:aws:acm:us-east-2:...`. To deploy the same DNS name in another Region, request or import a cert there too

**What `CertificateArn` looks like**

```text
arn:aws:acm:<region>:<account-id>:certificate/<certificate-id>
```

`deploy.py` does not create this certificate; it consumes an existing ARN and passes it to the NLB TLS listeners. ARNs in this guide like `arn:aws:acm:us-east-1:123456789012:certificate/12345678-...` are placeholders. See the AWS docs for [ACM regional behavior](https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html#acm-regions), [DNS validation](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html), and [`request-certificate`](https://docs.aws.amazon.com/cli/latest/reference/acm/request-certificate.html).

**Certificate options for private deployments**

| Option | Public DNS required? | Notes |
|---|---:|---|
| ACM Private CA certificate | No | Best fit for fully private enterprise networks when clients already trust the private CA. AWS Private CA has separate cost and CA lifecycle management. |
| Imported enterprise certificate | No | Use an existing internal PKI. Import the cert and key into ACM in the same Region as the stack. Customer owns renewal and re-import. |
| ACM public certificate for a privately resolved name | Public validation only | The Neo4j DNS record can remain private. ACM still needs domain ownership validation through public DNS or email because public certificates cannot be validated solely from a VPC private hosted zone. |

The last option often causes confusion: the validation CNAME can be public, but the Neo4j service record does not need to be public. For example, ACM might validate `neo4j.prod.internal.example.com` through a public CNAME under `example.com`, while Route 53 private DNS resolves `neo4j.prod.internal.example.com` to the internal NLB only inside the customer's VPCs.

**Recommended private workflow.** Keep the base Neo4j stack internal. Use a private DNS name for `AdvertisedDNS`, use an ACM Private CA or imported internal certificate when the customer has private PKI, and let customer application stacks handle any user-facing access. That preserves encryption in transit and avoids requiring the Neo4j Marketplace stack itself to create public DNS or public ingress.

**Stack-managed private DNS.** For repeatable tests and simple private deployments, `deploy.py` defaults `CreatePrivateDns=true` in Private mode. With `PrivateDnsZoneName`, the stack creates a Route 53 private hosted zone associated with the stack VPC and creates an alias record for `AdvertisedDNS`. With `PrivateDnsHostedZoneId`, the stack creates only the alias record in an existing private hosted zone. Pass `--no-create-private-dns` if customer-managed DNS already owns the same `AdvertisedDNS` record.

**Residual risk.** Cluster-internal ports (5000, 6000, 7000, 7688) remain plaintext between cluster members, protected by the cluster security group. An actor with `ec2:RunInstances` permission to launch into the cluster subnet with the cluster security group, `ec2:CreateTrafficMirrorSession` targeting a cluster ENI, or root on any cluster node can observe replication traffic on the wire. For regulated workloads or shared-tenancy accounts where IAM blast radius extends beyond the cluster operator team, request cluster TLS before deploying.

---

## Local Deployment and Testing

For template developers deploying from source. The [Operator Guide](#operator-guide) covers day-to-day stack usage once the stack is running.

### Set Up a Certificate

The private stack requires an ACM certificate before deployment. `certificate.py` handles this and writes `.deploy/cert-*.json`, which `deploy.py` picks up automatically so you don't need to copy-paste the ARN.

**Option A — No domain (local testing only)**

Generate a self-signed cert and import it directly into ACM. No public DNS ownership or ACM validation is required:

```bash
cd neo4j-ee
./certificate.py --region us-east-2 --domain-name neo4j.test.local --self-signed
```

This is instant. The trade-off: clients must use a skip-validation scheme such as `bolt+ssc://` or `neo4j+ssc://` instead of `+s`. `deploy.py` records `SelfSignedCertificate=true` in the EE output file when it can match the cert to a local `certificate.py --self-signed` cert file, and the `validate-private` suite, `admin-shell`, `run-cypher`, and `uv run scripts/smoke-write.py` choose `+ssc` for those test stacks. In-VPC applications still need `AdvertisedDNS` to resolve. Private mode creates that private DNS record by default unless you pass `--no-create-private-dns`. The sample app also reads the EE output file and switches away from system trust for self-signed test deployments.

**Option B — Real domain with Route 53**

If the domain is in a Route 53 hosted zone in this account, `--auto-route53` creates the validation CNAME and waits for issuance automatically:

```bash
./certificate.py --region us-east-2 --domain-name neo4j-test.yourdomain.com --auto-route53
```

**Option C — Real domain, DNS elsewhere**

If your DNS is at another provider (Cloudflare, Namecheap, etc.), omit `--auto-route53`. The script prints the validation CNAME, you add it manually, and it polls until ACM issues the cert:

```bash
./certificate.py --region us-east-2 --domain-name neo4j-test.yourdomain.com
```

**After any option:** `deploy.py` reads the cert ARN and domain from `.deploy/cert-*.json` automatically — no flags needed.

**Choosing a domain name.** The string is the cert SAN and Neo4j's advertised address. For Options B and C, two DNS records are needed: the ACM validation CNAME (created by `certificate.py`) and a service record pointing the name to the NLB. Private mode creates the service record by default. ExistingVpc mode can create it with `--create-private-dns`, or you can provide customer-managed DNS. For Option A, no public DNS records are needed, but in-VPC application clients still need private DNS.

`certificate.py` reuses an existing `ISSUED` or `PENDING_VALIDATION` cert for the same domain and region rather than requesting a new one. Pass `--no-wait` to print the CNAME and exit without polling.

See [Certificate options for private deployments](#tls-architecture) in the Architecture section for Private CA and imported-cert alternatives.

### Build

Regenerate the output template after editing any file in `templates/src/`:

```bash
cd neo4j-ee/templates
python build.py
```

Commit both the edited partial and the regenerated `neo4j-private.template.yaml`.

### Deploy

Run `certificate.py` first (see [Set Up a Certificate](#set-up-a-certificate)). `deploy.py` reads the cert ARN, domain name, and region from `.deploy/cert-*.json` automatically.

```bash
cd neo4j-ee

# Simplest — cert file auto-detected, region from cert file:
./deploy.py

# Override instance type or server count:
./deploy.py --number-of-servers 1
./deploy.py r8i.xlarge

# Pass cert explicitly if you have multiple cert files or want to be precise:
./deploy.py --cert-arn <arn> --advertised-dns <dns> --region us-east-2

# Private mode creates a private hosted zone and AdvertisedDNS alias by default:
./deploy.py --cert-arn <arn> --advertised-dns neo4j.test.local \
  --private-dns-zone test.local

# Or write the AdvertisedDNS alias into an existing private hosted zone:
./deploy.py --cert-arn <arn> --advertised-dns neo4j.internal.example.com \
  --create-private-dns --private-dns-hosted-zone-id Z1234567890ABC

# Use customer-managed DNS instead:
./deploy.py --cert-arn <arn> --advertised-dns neo4j.internal.example.com \
  --no-create-private-dns

# Use the published Marketplace AMI:
./deploy.py --marketplace

# Enable CloudWatch alarm email notifications:
./deploy.py --alert-email you@example.com
```

The default mode is Private. No `--mode` flag needed. Stack creation takes 5-10 minutes. The script writes outputs to `.deploy/<stack-name>.txt`.

> **Cost note.** Private mode provisions 3 NAT Gateways for a cluster (~$0.045/hr each) or 1 for a single instance. Tear down promptly after testing.

### Local Dry Run

Use `--dry-run` to confirm the command shape, selected template, region, instance type, and CloudFormation parameters without making AWS API calls:

```bash
cd neo4j-ee

./deploy.py --dry-run --number-of-servers 1 --region us-east-2 r8i.xlarge \
  --cert-arn arn:aws:acm:us-east-2:123456789012:certificate/12345678-1234-1234-1234-123456789012 \
  --advertised-dns neo4j.prod.internal.example.com
```

For a deeper local check after template edits, run:

```bash
python3 templates/build.py --verify
python3 -m py_compile deploy.py
cfn-lint templates/neo4j-private.template.yaml
```

### Preflight and Basic Validation

```bash
cd neo4j-ee/validate-private

uv run preflight <stack-name>                  # 11 checks: stack, bastion, endpoints

uv run validate-private                        # most recent deployment
uv run validate-private --stack <stack-name>   # specific deployment
```

`validate-private` runs 8 checks via the bastion: Bolt connectivity, server edition, listen address, memory configuration, data directory, APOC, GDS, and cluster roles (1 writer, expected follower count). Each check takes 3-5 seconds. Total time under 35 seconds.

### Smoke Test

```bash
uv run scripts/smoke-write.py                       # 20 CREATE/DELETE iterations
uv run scripts/smoke-write.py <stack-name> 50       # custom iteration count
```

Runs write operations through the cluster via the bastion. Each iteration uses a fresh driver connection to exercise routing table handling.

### Failover Suite

```bash
cd neo4j-ee/validate-private
uv run validate-private --stack <stack-name> --suite failover
```

Four cases using `systemctl stop`/`start` via SSM; no instance termination:

| Case | What it does | Typical runtime |
|---|---|---|
| `follower-with-data` | Stop a follower, write data, restart, verify data visible | ~60 s |
| `leader` | Stop the leader, verify election, write on new leader | ~90 s |
| `rolling` | Stop each node in turn; cluster stays available throughout | ~4-15 min |
| `reads` | Stop two followers; verify reads still served by remaining nodes | ~90 s |

### Resilience Suite

```bash
cd neo4j-ee/validate-private
uv run validate-private --stack <stack-name> --suite resilience
```

Two cases that terminate EC2 instances and wait for ASG replacement:

| Case | What it does | Timeout |
|---|---|---|
| `single-loss` | Terminate 1 node; verify EBS reattach, sentinel data intact, quorum reforms | 900 s |
| `total-loss` | Terminate all 3 nodes; verify all 3 volumes reattach, sentinel intact | 1200 s |

Each case writes a sentinel file to the data volume before termination and verifies it survives on the replacement instance, confirming `DeletionPolicy: Retain` and NVMe device resolution both work.

### Tear Down

```bash
./teardown.sh <stack-name>
./teardown.sh --delete-volumes <stack-name>   # also permanently deletes EBS volumes
```

If the sample private app is deployed, tear it down first or stack deletion will stall on its security group ingress rules:

```bash
cd neo4j-ee/sample-private-app && ./teardown-sample-private-app.sh <stack>
cd neo4j-ee && ./teardown.sh --delete-volumes <stack>
```

### Troubleshooting

**"Bastion SSM PingStatus = Online" fails**
The bastion UserData may still be running in the first 3 minutes after stack creation. Retry after waiting. If the check still fails after 10 minutes, confirm the bastion's IAM role has `AmazonSSMManagedInstanceCore` and the VPC has `ssm` and `ssmmessages` interface endpoints.

**"AccessDenied" on `GetSecretValue` or `GetParameter`**
The bastion's IAM role does not have access to the secret or SSM parameter for this stack. The policy scopes to `neo4j/<stack-name>/password` and `/neo4j-ee/<stack-name>/*`. Re-deploying the stack re-creates the policy with the correct scope.

**"NotALeader" error in Neo4j Browser**
The NLB routed a write to a follower. Use `uv run admin-shell` for writes: `neo4j+s://` or `neo4j+ssc://` routing directs writes to the leader automatically.

**Bastion Python checks fail but SSM is Online**
The bastion installs Python 3.11 alongside the AL2023 system Python 3.9, with `neo4j` and `boto3` under 3.11. If package installation failed during UserData, reinstall via SSM:

```bash
aws ssm send-command \
  --instance-ids <bastion-id> \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"python3.11 -m pip install 'neo4j>=6,<7' boto3\"]" \
  --region <region>
```

Check `cloud-init-output.log` for the root cause first:

```bash
aws ssm send-command \
  --instance-ids <bastion-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -50 /var/log/cloud-init-output.log"]' \
  --region <region>
```

**Mounting an existing EBS snapshot and resetting the password**

> **TL;DR:** Disable auth → set password via Cypher → re-enable auth. Repeat steps 2-3 per node in a cluster.

When a data volume is restored from a snapshot, the Neo4j system database on that volume already contains the auth store from the original deployment. The password in Secrets Manager will not match, producing `Neo.ClientError.Security.Unauthorized` on every connection.

`neo4j-admin dbms set-initial-password` does not help here. It only takes effect when the system database has never been initialized. On a snapshot restore the system database already exists, so the command is silently ignored.

The correct procedure is to disable authentication temporarily, set the password via Cypher, then re-enable:

```bash
# 1. Remove any existing auth_enabled entries and disable auth
aws ssm send-command --instance-ids <node-id> --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "systemctl stop neo4j",
    "sed -i \"/dbms.security.auth_enabled/d\" /etc/neo4j/neo4j.conf",
    "echo \"dbms.security.auth_enabled=false\" >> /etc/neo4j/neo4j.conf",
    "systemctl start neo4j"
  ]' --region <region>

# 2. Once Neo4j is up, set the password to match Secrets Manager
PASSWORD=$(./scripts/get-password.sh 2>/dev/null)
aws ssm send-command --instance-ids <node-id> --document-name AWS-RunShellScript \
  --parameters "commands=[
    \"for i in \$(seq 1 30); do cypher-shell -a bolt+ssc://localhost:7687 -u neo4j -p \\\"\\\" \\\"RETURN 1\\\" >/dev/null 2>&1 && break || sleep 3; done\",
    \"cypher-shell -a bolt+ssc://localhost:7687 -u neo4j -p \\\"\\\" \\\"ALTER USER neo4j SET PASSWORD '${PASSWORD}' CHANGE NOT REQUIRED\\\"\"
  ]" --region <region>

# 3. Re-enable auth
aws ssm send-command --instance-ids <node-id> --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "systemctl stop neo4j",
    "sed -i \"/dbms.security.auth_enabled/d\" /etc/neo4j/neo4j.conf",
    "echo \"dbms.security.auth_enabled=true\" >> /etc/neo4j/neo4j.conf",
    "systemctl start neo4j"
  ]' --region <region>
```

Get `<node-id>` from the ASG:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names <Neo4jNode1ASGName> \
  --region <region> \
  --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
  --output text
```

The `<Neo4jNode1ASGName>` value is in `.deploy/<stack-name>.txt`. For a three-node cluster, repeat steps 2 and 3 for each node's ASG (`Neo4jNode2ASGName`, `Neo4jNode3ASGName`).

> **Note:** `dbms.security.auth_enabled` may appear multiple times in `neo4j.conf` if the recovery procedure is run more than once. Neo4j 5 treats duplicate keys as a fatal config error and refuses to start. The `sed -i "/dbms.security.auth_enabled/d"` step above removes all occurrences before adding a single clean entry, which prevents this.

Reference: [Recover admin user and password — Neo4j Operations Manual](https://neo4j.com/docs/operations-manual/current/authentication-authorization/password-and-user-recovery/)

---

## EBS Snapshots

`snapshot.sh` creates EBS snapshots of all Neo4j data volumes for a deployed stack. Snapshots are incremental and stored in AWS-managed S3; snapshot size reflects used blocks only, not the allocated volume size.

```bash
./snapshot.sh                  # most recent deployment
./snapshot.sh <stack-name>     # specific deployment
./snapshot.sh --list           # list all snapshots for the most recent deployment
./snapshot.sh --list <stack-name>  # list all snapshots for a specific deployment
```

The script reads `.deploy/<stack-name>.txt` for volume IDs and region. Each snapshot is tagged with the stack name and date. For a three-node cluster all three volumes are snapshotted in the same run.

`--list` queries by the `stack` tag and shows snapshot ID, timestamp, state, progress, volume size, and description.

**Note on memory.** The `neo4j-admin database backup` recovery phase runs inside the Neo4j JVM and competes with the running database for heap. On an `r8i.xlarge` (32 GB) with a 19.3 GB heap and a 21.5 GB store, the combined footprint exceeds available RAM and triggers an OOM kill. EBS snapshots do not touch the JVM; they are taken at the block-device level and are safe to run on any instance size without restarting Neo4j.
