# AWS Markpletace CloudFormation Template for Neo4j Enterprise (Private EC2 Instances)

## Description

This custom CloudFormation Template (CFT) provides a method of deploying Neo4j with PRIVATE EC2 instances behind an INTERNET-FACING Network Load Balancer.

NOTE:  This CFT can take up to 10 minutes to deploy.  It won't show as "CREATE COMPLETE" in the AWS CloudFormation console until all AWS resources have been deployed AND the Neo4j Cluster is up, running and available.

## Cloud Topology
AWS Resources will be deployed as per the following diagram (this example depicts a 3 node Neo4j cluster):
![](images/neo4j-aws-3-node-private-nodes.png?raw=true)

## Installation Instructions

A) Deploy the CloudFormation template in the usual way, either by uploading the CFT to the CloudFormation section of the AWS console, or by running the deploy.sh script.  Remember to take a look inside the deploy.sh script and understand the variables that need to be set before executing it:

```
#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j-new.template.yaml"
#REGION=`aws configure get region`
REGION=us-east-1

Password="foo123"
NumberOfServers="3"
BastionSSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.1.0
SSHKeyName="EdTest-us-east-1"

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--disable-rollback \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=GraphDatabaseVersion,ParameterValue=${GraphDatabaseVersion} \
ParameterKey=NumberOfServers,ParameterValue=${NumberOfServers} \
ParameterKey=BastionSSHCIDR,ParameterValue=${BastionSSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False \
ParameterKey=SSHKeyName,ParameterValue=${SSHKeyName}
```

Note: The deploy.sh script takes a single command-line argument, which is the desired name of the Cloudformation Stack:
```
./deploy.sh my-neo4j-cft
{
    "StackId": "arn:aws:cloudformation:us-east-1:540622579701:stack/nlb-with-ssl/535f3180-5c50-11ed-a315-1260d77cfdf9"
}
```

# AWS Markpletace CloudFormation Template for Neo4j Enterprise

These CloudFormation Templates are also used to Neo4j to deploy the official Neo4j offering into the AWS Marketplace. 

Therefore, the easiest method to deploy Neo4j on AWS Elastic Compute Cloud (EC2) instances, is to go directly to the [Neo4j Listing in the AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4)

# Provisioned Resources
The following resources are created by the CFT, and users will need to ensure they have the correct permissions within AWS to provision them:

_Users are reminded that the deployment of cloud resources will incur costs._

- 1 VPC, with a CIDR Range of 10.0.0.0/16
- 6 Subnets, distributed evenly across 3 Availability zones, with the following CIDR Ranges:
  - [Public Subnet 1]  10.0.1.0/24
  - [Public Subnet 2]  10.0.2.0/24
  - [Public Subnet 3]  10.0.3.0/24
  - [Private Subnet 1] 10.0.4.0/24
  - [Private Subnet 2] 10.0.5.0/24
  - [Private Subnet 3] 10.0.6.0/24
- 1, or between 3 and 10 EC2 instances (Depending on whether a single instance, or an autonomous cluster is selected)
- 1 Network (Layer 4) Load Balancer
- 1 NAT Gateway

## Common Considerations
- The simplest way to deploy Neo4j on an IaaS environment is to use the [Neo4j Listing in the AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4)
- Users are reminded that the provisioning of cloud resources will incur costs
- Users will need to ensure that they have the correct permissions with AWS to deploy the CFT and create the associated cloud resources
- Autoscaling groups are included as part of this topology which means that EC2 instances will be re-created if deleted.  This should be considered default and expected behaviour.
- To delete all resources, users should delete the CloudFormation template, rather than attempting to delete individual resources within AWS.