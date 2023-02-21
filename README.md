# amazon-cloud-formation-neo4j

This repository contains a number of AWS CloudFormation Templates (CFTs), created and maintained by Neo4j.


| Template Name | Location | Description |
| ------------- | -------- | ----------- |
| Neo4j Enterprise | [neo4j-enterprise](/neo4j-enterprise/) | CloudFormation template to deploy neo4j enterprise edition |
| Neo4j Community  | [neo4j-community](/neo4j-community/)   | CloudFormation template to deploy neo4j community edition  |
| Custom Templates | [custom-templates](/custom-templates/  | CloudFormation templates for various custom use cases      |

Most significantly, this repository hosts the CFT for the Neo4j Enterprise listing on the AWS Marketplace.  This CFT can be found in the [neo4j-enterprise](/neo4j-enterprise/) folder.

> ### Please see the [Official Neo4j Operations Manual](https://neo4j.com/docs/operations-manual/current/cloud-deployments/neo4j-aws/) for more detailed installation instructions.

The custom-templates [custom-templates](/custom-templates/) folder contains some additional CFTs which have been created to incorporate specific changes to offer functionality beyond what is contained within the 'marketplace' CFT.
