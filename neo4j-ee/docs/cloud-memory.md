# CloudWatch Memory Monitoring for Neo4j EE

## Checking current memory usage

```bash
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)

aws cloudwatch get-metric-statistics \
  --namespace CWAgent \
  --metric-name mem_used_percent \
  --dimensions Name=InstanceId,Value=<instance-id> \
  --start-time $START \
  --end-time $END \
  --period 60 \
  --statistics Average \
  --region <region>
```

Get the instance ID from `.deploy/<stack-name>.txt` via the ASG:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names <Neo4jNode1ASGName from .deploy file> \
  --region <region> \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus]'
```

Verify the agent is installed and reporting before querying:

```bash
aws cloudwatch list-metrics \
  --namespace CWAgent \
  --dimensions Name=InstanceId,Value=<instance-id> \
  --region <region>
```

## Installing CloudWatch Agent on a running stack

The Neo4j IAM role only includes `AmazonSSMManagedInstanceCore` by default. Three steps:

**1. Attach the CloudWatch policy to the instance role**

```bash
# Get the role name from the instance profile
PROFILE_NAME=<stack-name>-Neo4jInstanceProfile-<suffix>
ROLE=$(aws iam get-instance-profile \
  --instance-profile-name $PROFILE_NAME \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)

aws iam attach-role-policy \
  --role-name $ROLE \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
```

**2. Install the agent via SSM**

```bash
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name AWS-ConfigureAWSPackage \
  --parameters '{"action":["Install"],"name":["AmazonCloudWatchAgent"]}' \
  --region <region>
```

Wait for completion:

```bash
aws ssm get-command-invocation \
  --command-id <command-id> \
  --instance-id <instance-id> \
  --region <region> \
  --query '[StatusDetails,StandardErrorContent]'
```

**3. Push config and start the agent**

```bash
aws ssm put-parameter \
  --name /neo4j-ee/<stack-name>/cw-agent-config \
  --type String \
  --overwrite \
  --value '{
  "metrics": {
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["/"] }
    }
  }
}' \
  --region <region>

aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name AmazonCloudWatch-ManageAgent \
  --parameters '{
    "action": ["configure"],
    "mode": ["ec2"],
    "optionalConfigurationSource": ["ssm"],
    "optionalConfigurationLocation": ["/neo4j-ee/<stack-name>/cw-agent-config"],
    "optionalRestart": ["yes"]
  }' \
  --region <region>
```

## Why this matters for Neo4j EE

Neo4j's page cache and GDS in-memory graph projections consume most available RAM. The EC2
`mem_used_percent` metric is the only way to observe this from outside the instance — the
standard EC2 CloudWatch namespace does not include memory. At 88%+ utilization on an
`r8i.xlarge` (32 GB), there is insufficient headroom for concurrent GDS workloads.

The CloudWatch Agent is not installed by default in the CloudFormation templates. It must be
added manually per stack (as above), or `CloudWatchAgentServerPolicy` must be added to the
IAM role in the template and the agent installed via UserData.
