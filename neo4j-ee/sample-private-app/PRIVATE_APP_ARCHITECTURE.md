# Building Applications That Access a Private Neo4j EE Deployment

> Status: working plan + architecture decision trace. Will evolve into the
> long-form application architecture guide for the Private deployment mode.

This document explains the contract between the Neo4j EE CloudFormation stack
("the platform") and applications that consume it ("the app"), the changes
required to make that contract work in Private mode, and the rationale behind
each decision.

## 1. The problem we are solving

In Private mode, the Neo4j EE stack is deployed with:

- No public IP on any Neo4j instance.
- An **internal** Network Load Balancer (NLB) — only routable from inside the
  VPC.
- Interface VPC endpoints for `ssm`, `ssmmessages`, and `logs` with
  `PrivateDnsEnabled: true`. This means inside the VPC, the regional hostnames
  (e.g. `ssm.us-east-1.amazonaws.com`) resolve to **endpoint ENIs**, not the
  public AWS endpoints.
- A gateway endpoint for `s3`.

This posture is correct for production: nothing about Neo4j is reachable from
the internet, and SSM Agent control-plane traffic stays on AWS PrivateLink
rather than crossing NAT.

**The challenge:** an application that wants to talk to this private deployment
(e.g., a Lambda doing graph queries) lives in the same VPC and is subject to
the same DNS overrides. As soon as PrivateDnsEnabled is in effect, the app's
calls to AWS APIs are forced through the interface endpoints — which are
gated by a security group the app is not yet in. The symptom is: the app
hangs on `ssm.get_parameter(...)` or `cloudwatch.PutLogEvents`, with **no log
output** to diagnose what happened (because the log writes themselves are
blocked by the same SG).

We need the platform to expose enough surface area that an app can wire itself
up correctly **without** the platform having to know the app exists at deploy
time.

## 2. The architectural contract

The EE template publishes a stable "contract" via SSM parameters under
`/neo4j-ee/<stack-name>/`:

| Parameter | Purpose | Status |
|---|---|---|
| `/vpc-id` | VPC the app should attach to | already published |
| `/nlb-dns` | Internal NLB DNS for Bolt connections | already published |
| `/external-sg-id` | SG that already has 7687 ingress to Neo4j | already published |
| `/password-secret-arn` | Secrets Manager ARN for the Neo4j password | already published |
| `/vpc-endpoint-sg-id` | SG attached to the Interface VPC endpoints | **to add** |

The pattern: **the platform owns infra and publishes IDs; the app looks up the
IDs and attaches itself.** The platform never knows about specific apps; apps
never reach into platform internals.

This document calls this the **contract pattern**. It is the foundation for
everything below.

## 3. Why we need to publish the endpoint SG ID

There were three options for letting apps talk to the existing interface
endpoints. We considered them in the following order.

### Option A — Open the endpoint SG to the entire VPC CIDR

Add a blanket ingress rule to `VpcEndpointSecurityGroup`: TCP 443 from
`10.0.0.0/16`.

**Pro:** apps need zero configuration; anything in the VPC can call SSM/SM/Logs.

**Con:** loses the security boundary the SG was put there to enforce. A
compromised workload anywhere in the VPC gets free access to the SSM and
Secrets Manager control plane via PrivateLink. This is the "inside the firewall
= trusted" anti-pattern AWS specifically discourages.

**Rejected.**

### Option B — App attaches itself to `Neo4jExternalSecurityGroup`

Reuse the SG that Neo4j instances themselves use. That SG is already in the
endpoint SG's ingress list, so the app would inherit access.

**Pro:** no new SG to manage.

**Con:** conflates two roles. `Neo4jExternalSecurityGroup` exists to grant
**ingress** to Neo4j on 7687/7474. Apps that join it become indistinguishable
from Neo4j peers in flow logs and IAM/SCP rules. Also: every app that joins
this SG gets the same broad set of permissions, which is the same problem as
Option A in slower motion.

**Rejected.**

### Option C — Publish the endpoint SG ID; apps add their own SG as ingress

Each app creates its own purpose-built SG (e.g. `Neo4jLambdaSG`). At deploy
time the app:

1. Looks up `/vpc-endpoint-sg-id`.
2. Adds an ingress rule on the endpoint SG allowing 443 from its own SG.
3. Adds an egress rule on its own SG allowing 443 to the endpoint SG.

**Pro:**
- Each app's identity in flow logs / SG references is its own SG. Auditable.
- Removing an app removes its ingress rule. No orphaned grants.
- The platform still enforces "you must explicitly opt in" — there is no
  accidental drive-by access.
- Symmetric with how the app already connects to Neo4j: it adds an ingress
  rule to `Neo4jExternalSecurityGroup` for 7687.

**Con:** the app needs one more SSM parameter and one more SG rule. Trivial.

**Chosen.** This is the model the rest of this doc assumes.

#### Cross-stack SG mutation: `mutable=True` is load-bearing

Because the app stack adds an ingress rule to an SG owned by the EE
CloudFormation stack, the app's CDK code must import the endpoint SG with
`mutable=True`:

```python
endpoint_sg = ec2.SecurityGroup.from_security_group_id(
    self, "Neo4jEndpointSG", endpoint_sg_id, mutable=True,
)
endpoint_sg.add_ingress_rule(lambda_sg, ec2.Port.tcp(443), ...)
```

With `mutable=True`, CDK synthesizes an `AWS::EC2::SecurityGroupIngress`
resource in the **app stack** that references the EE-owned SG by ID. Things
worth knowing about this:

- The default has flipped between CDK versions; setting it explicitly removes
  ambiguity in code review.
- It establishes a one-way lifecycle dependency: deleting the app stack
  removes the ingress rule cleanly. Deleting the **EE stack** while the app
  stack still exists will fail at the `VpcEndpointSecurityGroup` delete step
  (CFN refuses to delete an SG with referenced rules). Tear down the app
  stack first.
- The pre-existing import of `Neo4jExternalSecurityGroup` only uses it as a
  peer (no rule mutation on it), so it does **not** need `mutable=True` today.
  We will still set it explicitly for consistency, so reviewers don't have to
  reason about which imports mutate and which don't.

## 4. Why we need a Secrets Manager interface VPC endpoint

The Lambda must call `secretsmanager:GetSecretValue` to fetch the Neo4j
password. There is currently **no** SM interface endpoint in the VPC, so SM
DNS resolves to the public endpoint and the call egresses via NAT Gateway.

This works today, but it is wrong on three axes:

1. **Cost.** Every Lambda invocation pays NAT data-processing for the SM call.
   At scale this is real money for what is fundamentally a control-plane API.
2. **Posture consistency.** The whole point of Private mode is that AWS API
   traffic stays on PrivateLink. SSM, SsmMessages, Logs, and S3 already do.
   Secrets Manager being the lone exception is surprising and bad documentation
   — readers will assume "if SSM is private, SM is private too."
3. **Flow log clarity.** With the interface endpoint, the SM call shows up as
   intra-VPC traffic to a known endpoint ENI. Without it, you just see
   anonymous 443 egress to a NAT IP.

Adding a `com.amazonaws.<region>.secretsmanager` interface endpoint with
`PrivateDnsEnabled: true` makes existing boto3 code (no endpoint URL override)
resolve SM to a private IP automatically. We attach it to the same
`VpcEndpointSecurityGroup` so the same opt-in model applies.

This also benefits the Neo4j EC2 instances, which fetch their password from SM
during UserData on first boot. They currently go through NAT for that call;
after this change they will not.

**Cost note.** Each interface VPC endpoint costs roughly **$7.30 per AZ per
month** (us-east-1 list price; varies by region), plus per-GB data processing.
The SM endpoint adds:

- **1-node Private deployment:** 1 endpoint × 1 AZ ≈ $7/month.
- **3-node Private cluster:** 1 endpoint × 3 AZs ≈ $22/month.

This is on top of the existing SSM, SsmMessages, and Logs interface endpoints
(same per-AZ math), so the Private mode "endpoint floor" goes from 3 endpoints
to 4. If you also add a future endpoint for, say, DynamoDB or Bedrock, budget
the same per-AZ cost again. The savings vs NAT data processing only break
even at meaningful invocation volumes — the real reason to add the endpoint is
posture and auditability, not cost.

## 5. Why CloudWatch Logs is silently broken today

This was the symptom that started the investigation, and it is worth a
dedicated section because it is the most counter-intuitive failure mode.

**Common belief:** "Lambda's CloudWatch Logs writes go through the Lambda
service infrastructure, so they work even when the function is in a VPC with
no internet access."

**Reality:** when a Lambda is VPC-attached, *all* outbound calls — including
PutLogEvents to CloudWatch — go through the ENI in your VPC. They are subject
to your VPC's DNS resolution and your security groups.

Combine that with `PrivateDnsEnabled: true` on the existing Logs interface
endpoint, and:

1. The Lambda calls `logs.<region>.amazonaws.com`.
2. VPC DNS resolves it to the Logs endpoint ENI.
3. The Lambda's SG has no egress rule to the endpoint SG (today: only
   `0.0.0.0/0:443`, which permits the connect attempt).
4. The endpoint's SG has no ingress rule from the Lambda's SG.
5. The TCP SYN is dropped.
6. boto retries silently for ~30s, then the function times out.
7. **Nothing is written to the log group**, because that is the very thing
   that just failed.

The Option C fix (Lambda SG ↔ endpoint SG ingress) restores Logs writes. After
that, the rest of this work is observable and debuggable.

## 6. Why we are tightening Lambda egress at the same time

Currently the Lambda's SG has:

- Egress 7687 → `Neo4jExternalSecurityGroup` (for Bolt to NLB) — correct.
- Egress 443 → `0.0.0.0/0` (for AWS APIs) — necessary today only because SM
  has no VPC endpoint.

Once Option C is in and the SM endpoint exists, **every** AWS API call the
Lambda makes resolves to a private IP inside the VPC CIDR. The
`0.0.0.0/0:443` rule becomes dead — and a foothold for any future code change
that accidentally reaches the public internet.

We replace it with:

- Egress 443 → `VpcEndpointSecurityGroup`

Net: the Lambda has zero authorized routes to the public internet. It can
talk to Neo4j and to AWS PrivateLink endpoints. Nothing else.

## 7. Why JSON log format, retention, and X-Ray

These three Lambda settings are uncontroversial best practice but are worth
being explicit about, since the symptom of having none of them is "we cannot
debug the thing":

- **`log_retention=ONE_MONTH`**: CDK's default is "never expire", which silently
  accumulates cost forever.
- **`logging_format=JSON`** (with `application_log_level=INFO`): structured
  logs are queryable in CloudWatch Logs Insights without custom parsers and
  carry request IDs automatically.
- **`tracing=ACTIVE`**: X-Ray sees the full Lambda → SSM → SM → Bolt path,
  including timings. Especially valuable for diagnosing the kind of network
  hangs we are fixing here — a missing SG rule shows up as a stalled segment
  rather than a generic timeout. Adds the AWS-managed
  `AWSXRayDaemonWriteAccess` policy to the function role.

X-Ray writes are non-VPC and do not require an interface endpoint.

## 8. Net architecture after these changes

```
                           +-------------------------+
                           |   App SG (per-app)      |
                           |   Egress: 7687→Neo4j SG |
                           |   Egress: 443→Endpoint  |
                           +-------------------------+
                                |             |
                       7687/Bolt|             |443/HTTPS
                                v             v
                  +-------------------+   +----------------------+
                  | Neo4j External SG |   | VpcEndpointSecurityGroup |
                  |  (NLB + instances)|   |  (SSM, SsmMessages,  |
                  +-------------------+   |   Logs, SecretsMgr)  |
                                          +----------------------+
                                                  |
                                                  | PrivateLink
                                                  v
                                          +----------------------+
                                          |  AWS service planes  |
                                          +----------------------+
```

No NAT traffic. No public-internet egress. App identity is its own SG.

## 9. Files that change

### `neo4j-ee/neo4j.template.yaml`

1. New resource: `SecretsManagerVpcEndpoint` (Condition: IsPrivate). Same
   subnets, same SG, same `PrivateDnsEnabled: true` as the SSM/Logs endpoints.
2. New resource: `Neo4jConfigVpcEndpointSgParameter`
   (`AWS::SSM::Parameter`, Condition: IsPrivate). Name:
   `/neo4j-ee/${AWS::StackName}/vpc-endpoint-sg-id`. Value:
   `!Ref VpcEndpointSecurityGroup`.

### `neo4j-ee/sample-private-app/deploy-sample-private-app.sh`

- Add `VPC_ENDPOINT_SG_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/vpc-endpoint-sg-id")`.
- Pass `-c vpcEndpointSgId=${VPC_ENDPOINT_SG_ID}` to `cdk deploy`.

### `neo4j-ee/sample-private-app/neo4j_demo/neo4j_demo_stack.py`

- Read `vpcEndpointSgId` from context.
- Import as
  `endpoint_sg = ec2.SecurityGroup.from_security_group_id(self, "Neo4jEndpointSG", endpoint_sg_id, mutable=True)`.
  The `mutable=True` is required because the next line mutates the imported SG
  (see §3 "Cross-stack SG mutation").
- Set `mutable=True` on the existing `from_security_group_id` import of
  `Neo4jExternalSecurityGroup` as well, for consistency (it is not strictly
  required there today).
- Replace `lambda_sg.add_egress_rule(Peer.any_ipv4(), 443, ...)` with
  `lambda_sg.add_egress_rule(endpoint_sg, 443, ...)`.
- Add `endpoint_sg.add_ingress_rule(lambda_sg, 443, ...)`.
- Add `log_retention=logs.RetentionDays.ONE_MONTH`,
  `logging_format=lambda_.LoggingFormat.JSON`,
  `application_log_level_v2=lambda_.ApplicationLogLevel.INFO`,
  `tracing=lambda_.Tracing.ACTIVE` to the Function.

### `neo4j-ee/PRIVATE_ACCESS_GUIDE.md`

- Document the new `/vpc-endpoint-sg-id` contract parameter.
- Document the SM interface endpoint.
- Add a "Building an app that uses this deployment" section pointing here.

## 10. Checklist

EE template (`neo4j-ee/neo4j.template.yaml`):
- [ ] Add `SecretsManagerVpcEndpoint` (interface, Condition: IsPrivate, attached
      to `VpcEndpointSecurityGroup`, `PrivateDnsEnabled: true`).
- [ ] Add SSM param `Neo4jConfigVpcEndpointSgParameter` publishing
      `!Ref VpcEndpointSecurityGroup` at `/neo4j-ee/<stack>/vpc-endpoint-sg-id`.

Deploy script (`deploy-sample-private-app.sh`):
- [ ] `require_ssm` the new `/vpc-endpoint-sg-id` param.
- [ ] Pass it to `cdk deploy` as `-c vpcEndpointSgId=...`.
- [ ] Echo it in the "Reading SSM parameters from EE stack..." block.

CDK app (`neo4j_demo/neo4j_demo_stack.py`):
- [ ] Read the new context value via `require_context("vpcEndpointSgId")`.
- [ ] Look up `endpoint_sg` with `mutable=True` (required — see §3).
- [ ] Set `mutable=True` on the `Neo4jExternalSecurityGroup` import too, for consistency.
- [ ] Add `endpoint_sg.add_ingress_rule(lambda_sg, 443, ...)`.
- [ ] Drop `lambda_sg`'s `0.0.0.0/0:443` egress rule.
- [ ] Add `lambda_sg` egress 443 → `endpoint_sg`.
- [ ] Set `log_retention=ONE_MONTH`, `logging_format=JSON`,
      `application_log_level_v2=INFO`, `tracing=ACTIVE` on the Function.

Docs:
- [ ] Update `neo4j-ee/PRIVATE_ACCESS_GUIDE.md` with the new contract param,
      the SM endpoint, and a pointer to this document.

Validation:
- [ ] Redeploy EE stack (Private mode) and the CDK app cleanly from scratch.
- [ ] Invoke the Lambda; confirm a 200 with `edition`, `nodes_created`, and
      a populated `routing_table`.
- [ ] Confirm CW Logs receive JSON-formatted entries (was silently empty before).
- [ ] Confirm an X-Ray service map for the function showing SSM, SM, and the
      Bolt segment.
- [ ] Spot-check VPC flow logs for the Lambda ENI: no NAT egress, all 443
      traffic to endpoint ENIs.

## 11. Open questions

- **Do we want a generic "client app" SG construct in the EE template?** Right
  now each app re-creates the lambda_sg-equivalent. We could publish a
  pre-baked SG that already has the correct egress + endpoint ingress, and
  apps just attach to it. Tradeoff: simplicity for the app vs. the same
  multi-tenant SG pitfall as Option B above. Punting for now; revisit if a
  second app appears.
- **Apps that need to call AWS APIs we have not added endpoints for** (e.g.
  DynamoDB, Bedrock). The current answer is "add another interface endpoint
  to the EE template." A future iteration of the contract could let apps
  declare which AWS services they need and the EE stack provisions endpoints
  on demand. Out of scope here.
