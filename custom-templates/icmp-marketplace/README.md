# AWS Marketplace CloudFormation Template for Neo4j Enterprise
This repository holds the Amazon CloudFormation Template (CFT) that deploys Neo4j Enterprise (version 4.4 or 5) on the Amazon Web Services (AWS) platform (optionally including Neo4j Graph Data Science and Neo4j Bloom)  

> ### Please see the [Official Neo4j Operations Manual](https://neo4j.com/docs/operations-manual/current/cloud-deployments/neo4j-aws/) for more detailed installation instructions.

These CloudFormation Templates are also used to Neo4j to deploy the official Neo4j offering into the AWS Marketplace. 

Therefore, the easiest method to deploy Neo4j on AWS Elastic Compute Cloud (EC2) instances, is to go directly to the [Neo4j Listing in the AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4)

# Provisioned Resources
The following resources are created by the CFT, and users will need to ensure they have the correct permissions within AWS to provision them:

_Users are reminded that the deployment of cloud resources will incur costs._

- 1 VPC, with a CIDR Range of 10.0.0.0/16
- 2 Subnets, distributed evenly across 2 Availability zones, with the following CIDR Ranges:
  - 10.0.1.0/24
  - 10.0.2.0/24
- 1, or between 3 and 10 EC2 instances (Depending on whether a single instance, or an autonomous cluster is selected)
- 1 Network (Layer 4) Load Balancer

The following diagram is shown by way of an example, the first depicts a single instance and the second depicts a 3-node cluster:

# Diagram: Single Neo4j Instance on AWS
![image](aws-1-instance.png)

# Diagram: Three Node Neo4j Cluster on AWS
![image](aws-3-instance-cluster.png)

## Common Considerations
- The simplest way to deploy Neo4j on an IaaS environment is to use the [Neo4j Listing in the AWS Marketplace](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4)
- Users are reminded that the provisioning of cloud resources will incur costs
- Users will need to ensure that they have the correct permissions with AWS to deploy the CFT and create the associated cloud resources
- Autoscaling groups are included as part of this topology which means that EC2 instances will be re-created if deleted.  This should be considered default and expected behaviour.
- To delete all resources, users should delete the CloudFormation template, rather than attempting to delete individual resources within AWS.

