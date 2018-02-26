## Overview

Test drive in Amazon land is called "Quick Start".

[Entry point to docs is here](https://aws-quickstart.github.io/)

## Dependencies

* `brew install packer`
* Install AWS CLI and authenticate

## Build Neo4j Enterprise AMI

You should specify edition (community/enterprise) and version.

Optionally, you can omit the AWS key variables and set them in your environment.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=3.3.3" \
    neo4j-enterprise.json
```

Check the variables at the top of the JSON file for other options you can override/set.

## List AMIs

```
for region in `aws ec2 describe-regions --query 'Regions[].{Name:RegionName}' --output text` ; do
  echo "REGION $region" 
  aws ec2 describe-images --filters Name=name,Values=\*neo4j\* --owners self --region $region;
done
```

Deregister example: `aws ec2 deregister-image --image-id ami-650be718 --region us-east-1`

## Create CloudFormation Stack

```
aws cloudformation create-stack \
   --stack-name myteststack \
   --template-body file://cf-deploy.json \
   --parameters ParameterKey=KeyPairName,ParameterValue=TestKey ParameterKey=SubnetIDs,ParameterValue=SubnetID1\\,SubnetID2
```