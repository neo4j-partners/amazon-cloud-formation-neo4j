# Private Cluster Quick Start

This guide walks through deploying a three-node Neo4j Enterprise Edition cluster in Private mode with Bolt TLS, validating it through the operator bastion, deploying the sample Lambda application, and tearing everything down cleanly.

Private mode places all Neo4j instances in private subnets behind an internal Network Load Balancer. No instance has a public IP. Access from an operator workstation goes through AWS Systems Manager Session Manager port-forwarding, tunnelled via a dedicated `t4g.nano` bastion that lives in the same VPC but is not registered as an NLB target.

---

## Prerequisites

**AWS tooling**

```bash
# AWS CLI v2
aws --version

# Session Manager Plugin (required for operator bastion tunnels)
brew install --cask session-manager-plugin
session-manager-plugin --version

# jq (required for TLS cert packaging in deploy.sh --tls)
brew install jq

# openssl (typically pre-installed on macOS)
openssl version
```

**Python tooling**

```bash
# Python 3.11+
python3 --version

# uv (package manager for the test suite and validator)
pip install uv

# AWS CDK v2 (for the sample application)
npm install -g aws-cdk
cdk --version
```

**AWS profiles**

Two accounts are used:

| Profile | Account | Purpose |
|---|---|---|
| `marketplace` | `385155106615` | Build the AMI only |
| `default` (or any) | Your test account | All other commands |

```bash
export AWS_PROFILE=default   # omit to use the default profile
```

All scripts read `AWS_PROFILE` from the environment.

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

The test checks SSH hardening and OS configuration via SSM with no SSH key required.

---

## 2. Deploy a three-node private cluster

From the `neo4j-ee/` directory:

```bash
./deploy.sh --number-of-servers 3
```

This defaults to `DeploymentMode=Private`, `InstanceType=t3.medium`, and a random supported region. To pin the region (recommended, avoids an AMI cross-region copy that adds 10-20 minutes):

```bash
./deploy.sh --number-of-servers 3 --region us-east-1
```

What the stack creates:

- VPC with three public subnets (NAT Gateways, one per AZ) and three private subnets (Neo4j instances)
- Internal NLB across the three private subnets
- Three Neo4j instances forming a Raft cluster
- `t4g.nano` operator bastion in a private subnet, not registered as an NLB target
- VPC interface endpoints for `ssm`, `ssmmessages`, `logs`, and `secretsmanager` with `PrivateDnsEnabled: true`
- SSM parameters published under `/neo4j-ee/<stack>/` for downstream consumers

The deploy writes outputs to `.deploy/<stack-name>.txt` including the stack name, region, password, and NLB DNS. Stack creation takes 5-10 minutes.

**Cost note.** Private mode provisions three NAT Gateways at roughly $0.045/hour each (~$32/month per NAT). Tear down promptly after testing.

---

## 3. Add Bolt TLS

Bolt TLS encrypts the client-facing connection on port 7687. It requires a certificate whose Subject Alternative Name matches the address Neo4j advertises in its routing table. Because that address is the NLB DNS, and the NLB DNS does not exist until the stack creates the NLB, the cert cannot be generated before the stack is deployed.

`deploy.sh --tls` handles this with a two-phase flow built into the same invocation:

```bash
./deploy.sh --number-of-servers 3 --region us-east-1 --tls
```

**What `--tls` does, step by step:**

1. **Creates the stack without TLS** (Phase 1). Neo4j comes up with plain Bolt. The NLB DNS is now known.

2. **Reads the NLB DNS** from the SSM parameter the stack publishes at `/neo4j-ee/<stack>/nlb-dns`.

3. **Generates a self-signed certificate** using `openssl`. The certificate has one Subject Alternative Name: `DNS:<nlb-dns>`. This single SAN is sufficient because every cluster node sets `server.bolt.advertised_address` to the NLB DNS rather than its own private IP, so the routing table the driver receives always points back to the NLB.

   The openssl command used:
   ```bash
   openssl req -x509 -newkey rsa:4096 \
     -keyout private.key -out public.crt \
     -days 365 -noenc \
     -subj "/CN=${NLB_DNS}" \
     -addext "subjectAltName=DNS:${NLB_DNS}"
   ```

4. **Uploads the cert and key to Secrets Manager** as a single JSON secret with fields `certificate` and `private_key`. The upload uses `jq --rawfile` to avoid shell quoting problems with PEM newlines:
   ```bash
   jq -n --rawfile cert public.crt --rawfile key private.key \
     '{certificate:$cert, private_key:$key}' > secret.json
   aws secretsmanager create-secret \
     --name "neo4j-bolt-tls-${STACK_NAME}" \
     --secret-string file://secret.json
   ```

5. **Stages the CA bundle** at `sample-private-app/lambda/neo4j-ca.crt`. Because the cert is self-signed, the cert itself acts as its own CA. The Lambda bundles this file and uses it to verify the server certificate: real server authentication, not just wire encryption.

6. **Updates the CloudFormation stack** with the Secrets Manager ARN as the `BoltCertificateSecretArn` parameter. On each instance at next boot, UserData retrieves the secret, validates the JSON shape, writes the cert and key to `/var/lib/neo4j/certificates/bolt/`, and configures Neo4j with:
   ```
   dbms.ssl.policy.bolt.enabled=true
   dbms.ssl.policy.bolt.base_directory=/var/lib/neo4j/certificates/bolt
   dbms.ssl.policy.bolt.private_key=private.key
   dbms.ssl.policy.bolt.public_certificate=public.crt
   dbms.ssl.policy.bolt.client_auth=NONE
   server.bolt.tls_level=REQUIRED
   ```

7. **Triggers an ASG instance refresh** with `MinHealthyPercentage=0` to replace all three nodes immediately. The cluster re-forms on restart. The refresh takes roughly 5-10 minutes and is polled to completion before the script exits.

**TLS scope.** Phase 1 secures the client-facing Bolt port only. The HTTP browser endpoint (7474) and cluster-internal ports (6000/7000/7688) remain plaintext, protected by security group rules that restrict them to cluster members. See `README.md §Residual risk` for the specific threat vectors this leaves open.

---

## 4. Validate the stack

The validator runs checks via the operator bastion using SSM Run Command. No direct network path to Neo4j is needed from the operator workstation.

```bash
cd neo4j-ee/validate-private
```

First, confirm the stack and bastion are ready:

```bash
./scripts/preflight.sh
```

Expected output on a healthy stack:

```
=== Preflight Checks ===

  Stack:   test-ee-<timestamp>
  Region:  us-east-1
  Bastion: i-0abc123def456789

  [PASS] Stack status = CREATE_COMPLETE
  [PASS] Bastion SSM PingStatus = Online
  [PASS] neo4j Python driver installed on bastion
  [PASS] cypher-shell installed on bastion
  [PASS] Secret 'neo4j/test-ee-.../password' exists
  [PASS] Contract SSM params: vpc-id, nlb-dns, external-sg-id, password-secret-arn, vpc-endpoint-sg-id
  [INFO] Operational SSM params: region, stack-name, private-subnet-1-id, private-subnet-2-id
  [PASS] VPC interface endpoints: secretsmanager, logs, ssm, ssmmessages
  [PASS] Endpoint reachable: secretsmanager.us-east-1.amazonaws.com
  [PASS] Endpoint reachable: logs.us-east-1.amazonaws.com
  [PASS] Endpoint reachable: ssm.us-east-1.amazonaws.com
  [PASS] Endpoint reachable: ssmmessages.us-east-1.amazonaws.com

  11 passed, 0 failed
```

If the bastion SSM checks fail within the first 2-3 minutes of a fresh deploy, the bastion's UserData may still be running. Wait and retry.

Run the full validation suite:

```bash
uv run validate-private
```

This runs five checks through the bastion: Bolt connectivity, server edition, listen address, memory configuration, and data directory. Each check sends an SSM Run Command to the bastion; total time is under 35 seconds.

To target a specific stack by name:

```bash
uv run validate-private --stack test-ee-<timestamp>
```

---

## 5. Deploy the sample application

The sample application is a Python Lambda in the cluster's private subnets. It connects to Neo4j via `neo4j://` on the internal NLB, creates a small fintech graph (customers, accounts, transactions, merchants), and returns a cluster health report including the routing table and per-node state.

The Lambda uses a Function URL with `authType: AWS_IAM`. Calls require Sigv4 signing using existing AWS credentials.

When deployed after `deploy.sh --tls`, the Lambda automatically detects the CA bundle staged at `lambda/neo4j-ca.crt` and switches to `neo4j+s://` with strict server certificate verification. Without the bundle (a non-TLS deploy), it falls back to plaintext `neo4j://`.

```bash
cd neo4j-ee/sample-private-app
./deploy-sample-private-app.sh
```

The deploy script:
1. Reads the stack's SSM parameters (`vpc-id`, `nlb-dns`, `external-sg-id`, `password-secret-arn`, `vpc-endpoint-sg-id`)
2. Bootstraps the CDK environment (idempotent)
3. Deploys the CDK stack, which creates the Lambda, its security group, and the Function URL
4. Writes the Function URL to SSM at `/neo4j-cdk/<cdk-stack>/function-url`
5. Generates `invoke.sh` in the same directory

The Lambda's security group has two egress rules: TCP 7687 to the Neo4j external SG for Bolt, and TCP 443 to the VPC endpoint SG for SSM, Secrets Manager, and CloudWatch Logs. No traffic leaves the VPC.

To target a specific EE stack:

```bash
./deploy-sample-private-app.sh test-ee-<timestamp>
```

Invoke the Lambda:

```bash
./invoke.sh
```

Expected response:

```json
{
  "edition": "enterprise",
  "nodes_created": 10,
  "relationships_created": 9,
  "graph_sample": [...],
  "servers": [
    {"name": "...", "state": "Enabled", "health": "Available"},
    {"name": "...", "state": "Enabled", "health": "Available"},
    {"name": "...", "state": "Enabled", "health": "Available"}
  ],
  "routing_table": {
    "writers": 1,
    "readers": 2
  }
}
```

On first invocation the nodes and relationships are created. Subsequent invocations use `MERGE`, so the graph is idempotent. A `routing_table` with `writers: 1` and `readers: 2` confirms that a leader has been elected and the routing table is fully populated.

---

## 6. Tear down

Tear down the sample application first. The CDK stack adds an ingress rule to the EE stack's `VpcEndpointSecurityGroup`; deleting the EE stack while the CDK stack still exists will fail at the SG deletion step.

```bash
# From neo4j-ee/sample-private-app/
./teardown-cdk.sh
```

Then tear down the EE stack:

```bash
# From neo4j-ee/
./teardown.sh
```

`teardown.sh` deletes the CloudFormation stack, force-deletes the Neo4j password secret and the Bolt TLS cert secret (both with `--force-delete-without-recovery` to unblock same-name re-deployment), removes the staged `lambda/neo4j-ca.crt`, and removes the local `.deploy/<stack>.txt` file.

EBS data volumes have `DeletionPolicy: Retain` and survive stack deletion by design. `teardown.sh` prints the retained volume IDs. To permanently delete them:

```bash
./teardown.sh --delete-volumes
```
