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

Generate from Jinja template, upload to S3, and validate.

```
export VERSION=3.5.1
S3BUCKET=neo4j-cloudformation
GEN_STACK=neo4j-enterprise-stack-$VERSION.json
pipenv run python3 generate.py --edition enterprise --template deploy.jinja > $GEN_STACK && \
s3cmd -P put $GEN_STACK s3://$S3BUCKET/
aws cloudformation validate-template \
  --template-url https://s3.amazonaws.com/$S3BUCKET/$GEN_STACK > /dev/null
```

Neo4j Enterprise Standalone:

```
export VERSION=3.5.1
S3BUCKET=neo4j-cloudformation
GEN_STACK=neo4j-enterprise-standalone-stack-$VERSION.json
pipenv run python3 generate.py --edition enterprise --template deploy-standalone.jinja > $GEN_STACK && \
s3cmd -P put $GEN_STACK s3://$S3BUCKET/
aws cloudformation validate-template \
  --template-url https://s3.amazonaws.com/$S3BUCKET/$GEN_STACK > /dev/null
```

Neo4j Community Standalone:

```
export VERSION=3.5.1
S3BUCKET=neo4j-cloudformation
GEN_STACK=neo4j-community-standalone-stack-$VERSION.json
pipenv run python3 generate.py --edition community --template deploy-standalone.jinja > $GEN_STACK && \
s3cmd -P put $GEN_STACK s3://$S3BUCKET/
aws cloudformation validate-template \
  --template-url https://s3.amazonaws.com/$S3BUCKET/$GEN_STACK > /dev/null
```

CloudFormation can then be given these S3 URLs 
* `https://s3.amazonaws.com/neo4j-cloudformation/neo4j-enterprise-stack.json`
* `https://s3.amazonaws.com/neo4j-cloudformation/neo4j-enterprise-standalone-stack.json`

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

See the `deploy-stack.sh` shell script.

To get the status of a stack being deployed:

```
aws cloudformation describe-stacks --stack-name $STACKNAME --region $REGION | jq -r .Stacks[0].StackStatus
```

To delete

```
aws cloudformation delete-stack --stack-name $STACKNAME --region $REGION
```