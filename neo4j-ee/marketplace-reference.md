# Neo4j EE Marketplace: Architecture and CloudFormation Requirements

Reference document for the three-template split. Covers the recommended architecture for each template, the design decisions behind them, and the CloudFormation requirements AWS Marketplace enforces.

---

## Three Templates, Three Resource Topologies

AWS Marketplace allows up to three CloudFormation templates per AMI-based product listing. Using all three slots is only justified when the templates represent genuinely different infrastructure footprints. Each of the three Neo4j EE templates passes that test because the resource sets they create are structurally distinct, not parameter variations of each other.

### Template 1: Public

Creates a VPC, public subnets, an internet gateway, and an internet-facing Network Load Balancer. Instances sit in public subnets. No NAT gateways, no private subnets, no bastion, no VPC endpoints.

Target buyer: proof of concept, demos, and short-lived evaluation clusters. The template description must make clear that the database is reachable from outside the buyer's network perimeter and that this topology is not appropriate for production.

TLS parameters (`BoltCertificateSecretArn`, `BoltAdvertisedDNS`) are absent. Certificate management adds friction that evaluation deployments do not need and that buyers in this mode are unlikely to have in place.

### Template 2: Private

Creates a VPC, public subnets that carry NAT gateways, private subnets that carry the cluster nodes, VPC interface endpoints for Systems Manager and Secrets Manager, an SSM-connected bastion with no ingress rules, and an internal Network Load Balancer. Instances have no public IP addresses.

Target buyer: production and staging deployments where the buyer wants AWS to handle VPC setup and is willing to accept the template's network layout.

TLS parameters are present as optional fields. Production and regulated workloads frequently require TLS on the Bolt port; omitting the option would make this template unsuitable for its target buyer.

### Template 3: Private, Existing VPC

Accepts an existing VPC and existing private subnets. Creates the cluster nodes, internal NLB, security groups, IAM role, and Auto Scaling groups. Creates nothing related to VPC setup: no VPC, no subnets, no internet gateway, no NAT gateways, no route tables.

Target buyer: enterprises with pre-existing VPC infrastructure, often connected to on-premises networks via Direct Connect or VPN, where a separate network team controls which VPCs and subnets applications may use. These buyers cannot accept a template that creates a new VPC with a hardcoded CIDR.

TLS parameters are present as optional fields, for the same reasons as Template 2.

---

## Key Design Decisions

### TLS availability

TLS is available in Templates 2 and 3. It is not available in Template 1. The split follows security posture, not networking complexity. Public mode targets evaluation deployments where TLS adds friction without meaningful benefit. Both private templates target production workloads where TLS is a legitimate requirement.

### AllowedCIDR default

Template 2 defaults `AllowedCIDR` to `10.0.0.0/16` because it creates that VPC. Template 3 has no default. Any CIDR default in Template 3 is likely wrong for most enterprise buyers because their VPC CIDR is unknown to the template. A wrong default silently misconfigures the security group. The parameter description instructs the buyer to enter their VPC CIDR explicitly, with examples (`10.0.0.0/16`, `172.16.0.0/12`).

### Bastion in Template 3

Template 3 creates a bastion instance reachable only through AWS Systems Manager Session Manager. It has no ingress rules. The bastion is not optional because buyers deploying into an existing VPC may have network topologies where no other path exists to reach the internal NLB. The template description must explain that the bastion is created, what it does, and that it uses SSM rather than SSH. Buyers in environments with strict instance provisioning policies need this information before they launch.

### VPC endpoint creation in Template 3

Template 2 creates VPC interface endpoints for Systems Manager and Secrets Manager inside the VPC it creates. Template 3 deploys into a buyer-controlled VPC that may already have those endpoints. Creating a duplicate endpoint fails the deployment.

Two boolean parameters, `CreateSSMEndpoint` and `CreateSecretsManagerEndpoint`, both default to true. A buyer whose VPC already has centralized endpoint management sets the relevant parameter to false. The parameter description states plainly: set this to false if your VPC already has the endpoint, otherwise the deployment will fail with a duplicate resource error.

### NumberOfServers

All three templates offer 1 or 3 nodes, default 3. Limiting Template 1 to a single node would prevent buyers who need to test clustering behavior before moving to a private deployment. The AllowedCIDR parameter already prevents unrestricted public access. Instance costs are the buyer's decision.

---

## CloudFormation Best Practices for Marketplace

### Security group CIDR restriction

Application ports must be restricted to a parameterized CIDR range, never open to `0.0.0.0/0`. The `AllowedCIDR` parameter must carry an `AllowedPattern` that rejects `0.0.0.0/0` explicitly:

```yaml
AllowedCIDR:
  Type: String
  AllowedPattern: '^(?!0\.0\.0\.0/0$)(\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
  ConstraintDescription: The value 0.0.0.0/0 is not permitted.
```

The external security group applies this CIDR to Neo4j ports 7474 (HTTP) and 7687 (Bolt). Intra-cluster ports (5000, 6000, 7000, 7688, 2003, 2004, 3637) are restricted to the internal security group using a self-referential ingress rule. No port 22 ingress is created; operator access goes through SSM Session Manager.

### IAM least privilege

EC2 instances must use an IAM role, not long-term access keys. Each permission must name specific actions and scope resources to the minimum necessary:

- CloudFormation signaling: restrict to the current stack ARN using `!Sub`.
- EBS operations (`ec2:AttachVolume`, `ec2:DescribeVolumes`, `ec2:DescribeInstances`): resource `*` is acceptable because EBS volumes lack ARN-level scoping on all relevant APIs.
- Auto Scaling discovery (`autoscaling:DescribeAutoScalingGroups`): required for cluster node discovery; resource `*` is unavoidable.
- Secrets Manager (`secretsmanager:GetSecretValue`): restrict to the specific secret ARN when TLS is enabled using `!If [BoltTLSEnabled, !Ref BoltCertificateSecretArn, !Ref AWS::NoValue]`.

### Auto Scaling groups for all topologies

Single-node deployments must still use an Auto Scaling group (MinSize: 1, MaxSize: 1, DesiredCapacity: 1). The ASG replaces a failed instance automatically and the new instance reattaches the persistent EBS data volume. Three-node deployments use one ASG per node, each pinned to a single AZ.

### Multi-AZ using dynamic selection

Subnets must reference AZs dynamically using `Fn::GetAZs` and `Fn::Select`. Never hardcode AZ names (`us-east-1a`, `us-west-2b`). Three-node deployments place one node in each of the first three AZs for the region:

```yaml
AvailabilityZone:
  Fn::Select:
    - 0
    - Fn::GetAZs: !Ref 'AWS::Region'
```

### IMDSv2 enforcement

The LaunchTemplate must set `HttpTokens: required`. This is a hard Marketplace requirement for AMI-based products:

```yaml
MetadataOptions:
  HttpTokens: required
  HttpEndpoint: enabled
```

### AMI ID via SSM Parameter Store

The `ImageId` parameter must use `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>` type so the template resolves the correct AMI for each region. AWS Marketplace replaces this SSM parameter path with its own at subscription time. Hardcoded AMI IDs are region-specific and will fail outside the region where they were created.

### NAT gateways, not NAT instances

Private subnet outbound internet access must use managed NAT gateways (`AWS::EC2::NatGateway`). NAT instances require patching, do not scale automatically, and represent a single point of failure. NAT gateways are AWS-managed, highly available within an AZ, and support high bandwidth without configuration.

For single-node deployments, one NAT gateway in one public subnet is sufficient. For three-node deployments, one NAT gateway per AZ prevents AZ-level failure from blocking outbound traffic for nodes in other AZs.

### Password handling

The `Password` parameter must carry `NoEcho: true` so it does not appear in the CloudFormation console or event log. Apply a pattern that enforces minimum complexity:

```yaml
Password:
  Type: String
  NoEcho: true
  MinLength: 8
  AllowedPattern: '^(?=.*[a-zA-Z])(?=.*[0-9]).{8,}$'
  ConstraintDescription: Must be at least 8 characters and contain both letters and numbers.
```

### Parameter grouping metadata

The `AWS::CloudFormation::Interface` metadata block controls how parameters appear in the CloudFormation console. Group parameters by concern so buyers do not encounter TLS certificate fields before they have configured basic cluster settings:

```yaml
Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
      - Label:
          default: "AWS Marketplace"
        Parameters:
          - ImageId
      - Label:
          default: "Cluster Configuration"
        Parameters:
          - NumberOfServers
          - InstanceType
          - DataDiskSize
      - Label:
          default: "Network Access"
        Parameters:
          - AllowedCIDR
      - Label:
          default: "TLS (optional)"
        Parameters:
          - BoltCertificateSecretArn
          - BoltAdvertisedDNS
```

### Architectural diagrams

Each template requires a separate diagram submitted to the Marketplace seller portal. Dimensions: 1100x700 pixels. Use current AWS service icons. The diagram must accurately represent what that template deploys: a diagram showing NAT gateways and VPC endpoints is incorrect for the Public template; a diagram showing VPC creation is incorrect for the Existing VPC template.

---

## Marketplace Requirements Checklist

- [ ] No application ports open to `0.0.0.0/0`; `AllowedCIDR` parameter rejects it via `AllowedPattern`
- [ ] No SSH port (22) ingress in any security group; operator access via SSM Session Manager only
- [ ] IAM role uses specific actions and scoped resource ARNs; no wildcard permissions
- [ ] All EC2 instances launched through Auto Scaling groups, including single-node deployments
- [ ] AZs selected dynamically via `Fn::GetAZs`; no hardcoded AZ names
- [ ] `HttpTokens: required` in LaunchTemplate metadata options (IMDSv2 enforcement)
- [ ] `ImageId` uses `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>` type for region portability
- [ ] NAT gateways used for private subnet outbound; no NAT instances
- [ ] `Password` parameter carries `NoEcho: true`
- [ ] Default CIDR values do not allow ingress to database ports from the public internet
- [ ] `AWS::CloudFormation::Interface` metadata groups parameters by concern
- [ ] Each template has a separate architectural diagram (1100x700 pixels, accurate to that template's resource set)
- [ ] All three generated templates pass `cfn-lint` before submission
- [ ] Templates tested across at least `us-east-1`, `us-west-2`, `eu-west-1`, and `ap-southeast-1`

---

## References

1. [CloudFormation Templates 101 for Sellers in AWS Marketplace](https://aws.amazon.com/blogs/awsmarketplace/cloudformation-templates-101-for-sellers-in-aws-marketplace/) — Covers IAM roles, Auto Scaling, password handling, and cluster deployment patterns for Marketplace sellers.

2. [Taking NAT to the Next Level in AWS CloudFormation Templates](https://aws.amazon.com/blogs/apn/taking-nat-to-the-next-level-in-aws-cloudformation-templates/) — NAT gateway vs. NAT instance comparison with CloudFormation examples; the case for per-AZ NAT gateways.

3. [Add CloudFormation templates to your product](https://docs.aws.amazon.com/marketplace/latest/userguide/cloudformation.html) — Official Marketplace requirements: AMI parameter handling, network security, nested stack parameters, maximum template count per listing.

4. [AWS CloudFormation template guidelines for AMI-based products](https://aws.amazon.com/blogs/awsmarketplace/aws-cloudformation-template-guidelines-ami-based-products-aws-marketplace/) — Confirms templates are topology slots, not version slots; describes how Marketplace handles AMI parameter injection.

5. [NAT gateway use cases](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-scenarios.html) — Architecture diagrams, routing table configuration, and testing private subnet internet access via NAT.

6. [Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) — SSM Session Manager as the replacement for SSH-based bastion access; no inbound ports required.

7. [AWS Marketplace AMI buyer guide — topology selection](https://docs.aws.amazon.com/marketplace/latest/buyerguide/buyer-server-products.html) — Describes CloudFormation templates as topology selectors from the buyer's perspective.
