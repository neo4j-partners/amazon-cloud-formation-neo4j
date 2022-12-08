# AWS Markpletace CloudFormation Template for Neo4j Enterprise (Private EC2 Instances)

## Description

This custom CloudFormation Template (CFT) provides a method of deploying Neo4j with a secure (SSL/TLS) connection between the client and the Network Load Balancer (NLB).   The EC2 instances are deployed in PRIVATE subnets behind an INTERNET FACING Network Load Balancer.  This means that the EC2 instances are not provisioned with Public IP addresses and are therefore not directly routable over the internet.  However, the Neo4j cluster will be made available as a result of the NLB and the additional PUBLIC subnets which are created.

Because the SSL/TLS connection is terminated at the NLB, all traffic after the NLB (inside the AWS environment) will remain unencrypted, including  traffic between the Neo4j EC2 instances.

NOTE:  This CFT can take up to 10 minutes to deploy.  It won't show as "CREATE COMPLETE" in the AWS CloudFormation console until all AWS resources have been deployed AND the Neo4j Cluster is up, running and available.

## Cloud Topology
AWS Resources will be deployed as per the following diagram (this example depicts a 3 node Neo4j cluster):
![](images/neo4j-aws-3-node-private-nodes-ssl.png?raw=true)

## Prerequisites
There are two vital prerequisites which must be met prior to deploying this template:

1) You have administrative access to an internet Domain and are able to create DNS entries against (hereafter known as "SSLDomain")

2) You have created (or are able to create) a TLS Certificate in AWS Certificate Manager, pointing to SSLDomain

If you attempt to run this CloudFormation Template without observing the pre-requisite steps, the CloudFormation template will fail and you will experience the following error:

<img src="images/create-failed.png" width="50%" height="50%" />

## Installation Instructions

_These steps assume that the prerequisites listed above are met.  In this example, the domain edrandall.uk will be used._

### Stage 1 - SSL Certificate Creation in AWS Certiciate Manager (ACM)
A) Request a public TLS certificate from ACM
![](images/request-certificate.png?raw=true)

B) Enter your SSLDomain and leave the "DNS Validation" box selected.
![](images/request-public-certificate.png?raw=true)

C) Your new certificate will be created and show as "pending validation"
![](images/cert-pending-validation.png?raw=true)

D) Click the Certificate ID and take note of the CNAME which will need to be created in your own DNS to 'prove' to AWS that you own and control this domain.

E) In your own provider's console, create the CNAME.
![](images/cname-dns-ownership.png?raw=true)

F) After a few minutes (could take longer depending on DNS propogation speeds) your new certificate should change status to "Issued"
![](images/cert-issued.png?raw=true)

### Stage 2 - CloudFormation Template Installation
A) Deploy the CloudFormation template in the usual way, either by uploading the CFT to the CloudFormation section of the AWS console, or by running the deploy.sh script.  Remember to take a look inside the deploy.sh script and understand the variables that need to be set before executing it:

```
#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j-new.template.yaml"
REGION=$(aws configure get region)

Password="foo123"
NumberOfServers="3"
BastionSSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.1.0
SSHKeyName="EdTest-us-east-1"

#Update with your SSLDomain
SSLDomain="neo4j.edrandall.uk"

#Update with the ARN of the Certificate from AWS Certificate Manager
CertificateARN="arn:aws:acm:us-east-1:540622579701:certificate/f544dc8f-887d-4b4a-929a-549234e178e7"

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
Note the following additional values which are required to configure SSL and are therefore not included in the standard Neo4j [AWS Markplace Template](../../marketplace/).  You will need to provide these values, either in the ./deploy.sh script or in the CloudFormation GUI. 
![](images/cft-config.png?raw=true)


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

### Stage 3 - Create CNAME to redirect "SSLDomain" to the Network Load Balancer

A) Once the CFT deployment is underway, you can log into the AWS console and make a note of the FQDN which allocated by AWS for the Network Load Balancer.  This is usually available within a minute or so after the template deployment has been started.  Once you have got this value, you can create the CNAME in your own DNS:
![](images/create-cname-for-nlb.png?raw=true)

B) Once the CloudFormation template has deployed, you will need to review the outputs and take note of the values shown.
![](images/outputs.png?raw=true)

C) Once the DNS records have propogated, your neo4j deployment can be accessed using your SSL domain. Note that you will need to enter the complete URL including the directory suffix:  https://SSLDOMAIN:7473/browser/

![](images/neo4j-behind-ssl?raw=true)

## Common Considerations
- The simplest way to deploy Neo4j on an IaaS environment is to use the [Neo4j Listing in the AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4)
- Users are reminded that the provisioning of cloud resources will incur costs
- Users will need to ensure that they have the correct permissions with AWS to deploy the CFT and create the associated cloud resources
- Autoscaling groups are included as part of this topology which means that EC2 instances will be re-created if deleted.  This should be considered default and expected behaviour.
- To delete all resources, users should delete the CloudFormation template, rather than attempting to delete individual resources within AWS.