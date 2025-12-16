# Marketplace
These are instructions to update the marketplace listing.  Unless you are a Neo4j employee doing so, you should not need to do any of this.

## Updating the Listing
The listing is managed in the portal [here](https://aws.amazon.com/marketplace/management/products/server).  You can update listing copy in that portal.

## Updating the AMI
The CFT depends on an AMI.  That AMI should be updated regularly to bring on patches.

First off, login to the [AWS console in us-east-1](https://us-east-1.console.aws.amazon.com/console/home).  Make you are in the neo4j-marketplace account.  If you're not in the right account and region the AMI won't be visible to the MP publishing pipeline.

This seems to have changed --- We've been using the AMI builder with the [build.sh](build.sh) script in this directory.  Marketplace has a requirement to disable password access to Marketplace VMs even though the platform images have it enabled.  The builder creates an AMI in a special builder account.  We've had to then copy that AMI to the publisher account manually because something in the Marketplace pipeline is broken.  This process seems like it's changing daily, so it's probably best to check with the AWS Marketplace operations people as you work through the process.

## Updating the CFT
With the AMI updated, you can update the CFT.  That is done by adding a new version in the portal.  You'll also need to update the ImageID parameter in the CFT.

* AMI ID - Should be the AMI you made earlier.
* IAM access role ARN - arn:aws:iam::385155106615:role/aws_marketplace_ami_ingestion
* CloudFormation template link - The form requires that the template be in S3.  You can upload it to https://marketplace-neo4j-enterprise-edition.s3.us-east-1.amazonaws.com/neo4j.template.yaml
* Architecture diagram link - While in this repo, it's also in a bucket here: https://marketplace-neo4j-enterprise-edition.s3.us-east-1.amazonaws.com/arch.png
