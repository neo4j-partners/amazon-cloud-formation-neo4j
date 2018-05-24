## Overview

Amazon Marketplace entry

## Dependencies

* Install AWS CLI and authenticate
* `pipenv install`

## Generate CloudFormation Template

The CloudFormation stack is a jinja template which evaluates to a CloudFormation JSON file.

Generate and copy to the right S3 bucket.  If the generate step fails due to a syntax
error, check the intermediate `generated.json` file, which contains raw jinja substitutions
before JSON parsing.

There are two possible templates you can use:
* `deploy.jinja` is for n-node causal clusters
* `deploy-standalone.jinja` is for single-node deploys

Causal clusters:

```
pipenv run python3 generate.py --template deploy.jinja > neo4j-enterprise-stack-test.json && \
s3cmd -P put neo4j-enterprise-stack-test.json s3://neo4j-cloudformation/
```

Standalone:

```
pipenv run python3 generate.py --template deploy-standalone.jinja > neo4j-enterprise-standalone-stack-test.json && \
s3cmd -P put neo4j-enterprise-standalone-stack-test.json s3://neo4j-cloudformation/
```

CloudFormation can then be given these S3 URLs 
* `https://s3.amazonaws.com/neo4j-cloudformation/neo4j-enterprise-stack.json`
* `https://s3.amazonaws.com/neo4j-cloudformation/neo4j-enterprise-standalone-stack.json`

### Validating a template locally

`aws cloudformation validate-template --template-body file://neo4j-enterprise-stack.json`

This often doesn't work and comes with numerous limitations.  One on filesize
(which doesn't apply to S3), another in that it doesn't validate everything.

## Testing Deployed Stacks

### Scanning Clusters after startup for debugging purposes

Check the `scan-cluster.sh` script, which can gather metrics for everything
in a deployed stack; useful if something is going wrong.

### Stress Tests

Run the stress tests in this repo, and verify with the followers that they
received all data.

### NMap

Run nmap to enumerate ports on the VMs and ensure that only bolt and HTTPS are open.

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
   --stack-name StackyMcGrapherston \
   --template-body file://neo4j-enterprise-stack.json \
   --parameters ParameterKey=ClusterNodes,ParameterValue=3 \
                ParameterKey=InstanceType,ParameterValue=m3.medium \
                ParameterKey=NetworkWhitelist,ParameterValue=0.0.0.0/8 \
                ParameterKey=Password,ParameterValue=s00pers3cret \
                ParameterKey=SSHKeyName,ParameterValue=davidallen-aws-neo4j \
                ParameterKey=VolumeSizeGB,ParameterValue=37 \
                ParameterKey=VolumeType,ParameterValue=gp2 \
  --capabilities CAPABILITY_NAMED_IAM
```