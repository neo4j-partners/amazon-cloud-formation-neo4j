## Overview

Amazon Marketplace entry

## Dependencies

* `brew install packer`
* Install AWS CLI and authenticate
* `pipenv install`

## Build Neo4j Enterprise AMI

You should specify edition (community/enterprise) and version.  Because this is debian based,
versions should match what is in the debian package repo.

You may omit the AWS key variables and set them in your environment.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:3.3.3" \
    packer-AMI-template.json
```

Check the variables at the top of the JSON file for other options you can override/set.

## Generate CloudFormation Template

The CloudFormation stack is a jinja template which evaluates to a CloudFormation JSON file.

`pipenv run python3 generate.py > neo4j-enterprise-stack.json`

This generates a raw template to `generated.json` and sends a pretty-printed organized template to the output file.

Validate (in development) the local generated template:

`aws cloudformation validate-template --template-body file://neo4j-enterprise-stack.json`

This JSON file can be uploaded to CloudFormation and created as a stack.

## List AMIs

```
for region in `aws ec2 describe-regions --query 'Regions[].{Name:RegionName}' --output text` ; do
  echo "REGION $region" 
  aws ec2 describe-images --filters Name=name,Values=\*neo4j\* --owners self --region $region;
done
```

Deregister example: `aws ec2 deregister-image --image-id ami-650be718 --region us-east-1`

## Create CloudFormation Stack

Check needed parameters in the generated CF stack file first, and do not copy/paste
the below, but customize it.

```
aws cloudformation create-stack \
   --stack-name myteststack \
   --template-body file://neo4j-enterprise-stack.json \
   --parameters ParameterKey=AvailabilityZone,ParameterValue=us-west-2a \
                ParameterKey=ClusterName,ParameterValue=neo4j-enterprise \
                ParameterKey=ClusterNodes,ParameterValue=3 \
                ParameterKey=InstanceType,ParameterValue=m3.medium \
                ParameterKey=NetworkWhitelist,ParameterValue=0.0.0.0 \
                ParameterKey=Password,ParameterValue=s00pers3cret \
                ParameterKey=SSHKeyName,ParameterValue=davidallen-aws-neo4j \
                ParameterKey=VMDiskSizeGB,ParameterValue=10 \
                ParameterKey=VolumeType,ParameterValue=standard
```