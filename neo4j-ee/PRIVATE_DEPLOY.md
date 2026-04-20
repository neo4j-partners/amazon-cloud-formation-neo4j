# Private Cluster Deployment Guide

Private mode places all Neo4j instances in private subnets behind an internal Network Load Balancer. No instance has a public IP. Operator access goes through AWS Systems Manager Session Manager port-forwarding, tunnelled via a dedicated `t4g.nano` bastion in the same VPC. Application workloads reach the NLB directly from within the VPC or over VPC peering.

For the design decisions behind this topology — NLB hairpin mitigation, Bolt TLS residual risk, URI scheme semantics — see [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## Prerequisites

**AWS tooling**

```bash
aws --version                                    # AWS CLI v2
brew install --cask session-manager-plugin       # required for SSM port-forward tunnels
session-manager-plugin --version
brew install jq                                  # required for --tls cert packaging
openssl version                                  # typically pre-installed on macOS
```

**Python tooling**

```bash
python3 --version       # 3.11+
pip install uv          # package manager for the test suite and validator
npm install -g aws-cdk  # CDK v2, for the sample application
cdk --version
```

**AWS profiles**

| Profile | Account | Purpose |
|---|---|---|
| `marketplace` | `385155106615` | Build the AMI only |
| `default` (or any) | Your test account | All other commands |

```bash
export AWS_PROFILE=default
```

---

## 1. Build the AMI

The AMI is a base Amazon Linux 2023 image with SSH hardening and OS patches. Neo4j is installed at deploy time from `yum.neo4j.com`. The build runs in the `marketplace` account.

```bash
cd neo4j-ee
AWS_PROFILE=marketplace ./marketplace/create-ami.sh
```

This launches a builder instance, runs the hardening script, creates an AMI, and writes its ID to `marketplace/ami-id.txt`. The build takes roughly 10 minutes.

Verify the AMI before deploying:

```bash
AWS_PROFILE=marketplace ./marketplace/test-ami.sh
```

The test checks SSH hardening and OS configuration via SSM — no SSH key required.

---

## 2. Deploy a Private Cluster

From the `neo4j-ee/` directory:

```bash
./deploy.sh --number-of-servers 3 --region us-east-1
```

Pinning the region avoids a cross-region AMI copy that adds 10-20 minutes. Omitting `--region` picks a random supported region.

What the stack creates:

- VPC with three public subnets (NAT Gateways, one per AZ) and three private subnets (Neo4j instances)
- Internal NLB across the three private subnets
- Three Neo4j instances forming a Raft cluster
- `t4g.nano` operator bastion in a private subnet, not registered as an NLB target
- VPC interface endpoints for `ssm`, `ssmmessages`, `logs`, and `secretsmanager` with `PrivateDnsEnabled: true`
- SSM parameters under `/neo4j-ee/<stack>/` for downstream consumers
- Neo4j password in Secrets Manager at `neo4j/<stack>/password`

Stack creation takes 5-10 minutes. The deploy script writes outputs to `.deploy/<stack-name>.txt`.

> **Cost note.** Private mode provisions three NAT Gateways at roughly $0.045/hour each. Tear down promptly after testing.

For a single-instance deployment:

```bash
./deploy.sh --number-of-servers 1 --region us-east-1
```

---

## 3. Add Bolt TLS

Bolt TLS encrypts the client-facing connection on port 7687. The certificate's Subject Alternative Name must match the address Neo4j advertises in its routing table, which is the NLB DNS. Because the NLB DNS does not exist until the stack creates the NLB, the cert cannot be generated before deployment.

`deploy.sh --tls` handles this with a two-phase flow:

```bash
./deploy.sh --number-of-servers 3 --region us-east-1 --tls
```

**What `--tls` does, step by step:**

1. Creates the stack without TLS. Neo4j comes up with plain Bolt. The NLB DNS is now known.

2. Reads the NLB DNS from the SSM parameter the stack publishes at `/neo4j-ee/<stack>/nlb-dns`.

3. Generates a self-signed certificate with the NLB DNS as the only SAN:

   ```bash
   openssl req -x509 -newkey rsa:4096 \
     -keyout private.key -out public.crt \
     -days 365 -noenc \
     -subj "/CN=${NLB_DNS}" \
     -addext "subjectAltName=DNS:${NLB_DNS}"
   ```

   A single SAN is sufficient because every cluster node advertises the NLB DNS in its routing table, not its own private IP. Every connection the driver opens after fetching the routing table points back to the NLB, and the cert validates against it every time.

4. Uploads the cert and key to Secrets Manager as a JSON secret:

   ```bash
   jq -n --rawfile cert public.crt --rawfile key private.key \
     '{certificate:$cert, private_key:$key}' > secret.json
   aws secretsmanager create-secret \
     --name "neo4j-bolt-tls-${STACK_NAME}" \
     --secret-string file://secret.json
   ```

5. Stages the CA bundle at `sample-private-app/lambda/neo4j-ca.crt`. Because the cert is self-signed, the cert itself is its own CA. The Lambda uses this file for server certificate verification.

6. Updates the CloudFormation stack with the Secrets Manager ARN as `BoltCertificateSecretArn`. On each instance at next boot, UserData retrieves the secret and configures Neo4j:

   ```
   dbms.ssl.policy.bolt.enabled=true
   dbms.ssl.policy.bolt.base_directory=/var/lib/neo4j/certificates/bolt
   dbms.ssl.policy.bolt.private_key=private.key
   dbms.ssl.policy.bolt.public_certificate=public.crt
   dbms.ssl.policy.bolt.client_auth=NONE
   server.bolt.tls_level=REQUIRED
   ```

7. Triggers an ASG instance refresh with `MinHealthyPercentage=0` to replace all three nodes. The cluster re-forms on restart. The refresh takes 5-10 minutes.

Phase 1 secures the client-facing Bolt port only. HTTP (7474) and cluster-internal ports (6000/7000/7688) remain plaintext. See [`ARCHITECTURE.md §Residual Risk`](ARCHITECTURE.md#residual-risk--cluster-replication-traffic) for the specific threat vectors this leaves open.

---

## 4. Connect from an Operator Workstation

Private mode instances have no public IP. Operator access goes through an SSM Session Manager port-forward tunnel via the operator bastion. The bastion (`t4g.nano`) exists for this purpose — it is in the same private subnet as the Neo4j instances but is not registered as an NLB target, which prevents the NLB hairpin failure described in [`ARCHITECTURE.md`](ARCHITECTURE.md#operator-bastion--nlb-hairpin).

The stack outputs include ready-to-run tunnel commands with the bastion instance ID and NLB DNS already substituted:

```bash
aws cloudformation describe-stacks \
  --stack-name <stack-name> --region <region> \
  --query 'Stacks[0].Outputs[?OutputKey==`Neo4jSSMHTTPCommand` || OutputKey==`Neo4jSSMBoltCommand`].[OutputKey,OutputValue]' \
  --output table
```

Run the commands in two terminals (or backgrounded with `&`). Then open `http://localhost:7474` in a browser or connect `bolt://localhost:7687`.

> **Note:** Connection strings generated inside Neo4j Browser will show the internal NLB DNS hostname rather than `localhost`. Substitute `localhost` for the hostname to connect through the open tunnel.

For the full operator workflow — validation, admin shell, Cypher queries, troubleshooting — see [`OPERATOR_GUIDE.md`](OPERATOR_GUIDE.md).

---

## 5. Connect from Application Workloads

Application tiers inside AWS reach the internal NLB directly without SSM tunnels. AWS Network Load Balancers support connections from clients over VPC peering, AWS managed VPN, Direct Connect, and third-party VPN solutions.

**Same VPC.** An application in the same VPC connects to the NLB's internal DNS name on port 7687 (Bolt) or 7474 (HTTP). Set `AllowedCIDR` to `10.0.0.0/16` at stack launch — no additional security group changes are needed for in-VPC clients.

**VPC Peering / Transit Gateway.** An application in a spoke VPC reaches the NLB's private IP addresses through the peering or TGW route. Two prerequisites: a route in the spoke VPC's route table pointing the Neo4j VPC CIDR at the peering connection or TGW attachment, and `AllowedCIDR` updated to include the spoke VPC's CIDR (e.g. `10.1.0.0/16`). The NLB DNS resolves directly to private IPs; no additional DNS configuration is required on the peering connection.

**Within the same subnet.** An application in the same subnet can connect directly to individual Neo4j node IPs on port 7687, bypassing the NLB. Use `bolt://<node-ip>:7687`. See [`ARCHITECTURE.md §NLB Routing and URI Scheme`](ARCHITECTURE.md#nlb-routing-and-uri-scheme) for why `neo4j://` should not be used with a direct node IP.

---

## 6. Platform Contract

The EE stack publishes resource IDs via SSM under `/neo4j-ee/<stack-name>/` so that applications and operator tooling can wire themselves up without knowing stack internals.

**Contract parameters** — required; all five must exist for the platform to be usable:

| Parameter | Purpose |
|---|---|
| `/neo4j-ee/<stack>/vpc-id` | VPC the application should attach to |
| `/neo4j-ee/<stack>/nlb-dns` | Internal NLB DNS for Bolt connections |
| `/neo4j-ee/<stack>/external-sg-id` | Security group with inbound 7687 to Neo4j instances |
| `/neo4j-ee/<stack>/password-secret-arn` | Secrets Manager ARN for the Neo4j password |
| `/neo4j-ee/<stack>/vpc-endpoint-sg-id` | Security group attached to the VPC interface endpoints |

**Operational parameters** — informational:

| Parameter | Purpose |
|---|---|
| `/neo4j-ee/<stack>/region` | AWS region |
| `/neo4j-ee/<stack>/stack-name` | Stack name |
| `/neo4j-ee/<stack>/private-subnet-1-id` | First private subnet |
| `/neo4j-ee/<stack>/private-subnet-2-id` | Second private subnet |

### VPC Interface Endpoints

A Private-mode stack provisions interface VPC endpoints for `ssm`, `ssmmessages`, `logs`, and `secretsmanager` with `PrivateDnsEnabled: true`. All four regional hostnames resolve to private IPs inside the VPC automatically — no endpoint URL overrides in application code.

The `secretsmanager` endpoint is required for two reasons:

1. Neo4j instances call `secretsmanager:GetSecretValue` during UserData on first boot to fetch the password. Without the endpoint, that call egresses via NAT.
2. VPC-attached Lambda functions route all outbound calls through their VPC ENI. Without a `secretsmanager` endpoint, Lambda calls to Secrets Manager also egress via NAT, adding latency and NAT data-processing charges for every cold start.

The `logs` endpoint has a sharper failure mode. With `PrivateDnsEnabled: true`, `logs.<region>.amazonaws.com` resolves to the endpoint ENI inside the VPC. The endpoint ENI is gated by the endpoint security group — a Lambda whose security group is not wired into that group cannot write to CloudWatch Logs. Because the failure is on the write path, nothing appears in the log group to indicate what went wrong. The endpoint security group contract (publishing `/vpc-endpoint-sg-id`) lets applications opt in without the platform needing to know about them at deploy time.

### Why Each Endpoint Design Decision Was Made

**Why publish the endpoint SG ID rather than opening the endpoint SG to the whole VPC CIDR.** A blanket `10.0.0.0/16` ingress rule on the endpoint security group lets any compromised workload in the VPC call SSM and Secrets Manager via PrivateLink. The published SG ID approach requires each application to explicitly add its own security group to the endpoint SG's ingress, creating an auditable per-application record and a clean removal path when the app is deleted.

**Why each application uses its own security group rather than joining `Neo4jExternalSecurityGroup`.** `Neo4jExternalSecurityGroup` grants ingress to Neo4j on ports 7687 and 7474. Applications that join it become indistinguishable from Neo4j peers in flow logs. The intended pattern is: each application creates its own purpose-built security group, adds ingress 443 to the endpoint SG, and adds egress 7687 to the Neo4j external SG. Two explicit references, both auditable.

---

## 7. Deploy the Sample Application

The sample application demonstrates the full connection pattern: a Python Lambda in the cluster's private subnets connecting to Neo4j via `neo4j://` on the internal NLB.

```bash
cd neo4j-ee/sample-private-app
./deploy-sample-private-app.sh
```

For the full architecture, rationale, and implementation guide, see [`APP_GUIDE.md`](APP_GUIDE.md).

---

## 8. Tear Down

Tear down the sample application first if deployed. The CDK stack adds an ingress rule to the EE stack's `VpcEndpointSecurityGroup`; deleting the EE stack while the CDK stack still exists fails at the security group deletion step.

```bash
# From neo4j-ee/sample-private-app/
./teardown-cdk.sh

# From neo4j-ee/
./teardown.sh
```

`teardown.sh` deletes the CloudFormation stack, force-deletes the Neo4j password secret and the Bolt TLS cert secret (both with `--force-delete-without-recovery` to unblock same-name re-deployment), removes the staged `lambda/neo4j-ca.crt`, and removes the local `.deploy/<stack>.txt` file.

EBS data volumes have `DeletionPolicy: Retain` and survive stack deletion by design. `teardown.sh` prints the retained volume IDs. To permanently delete them:

```bash
./teardown.sh --delete-volumes
```
