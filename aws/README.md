## Overview

Amazon Marketplace entry

## Dependencies

* Install AWS CLI and authenticate
* `pipenv install`

## AWS CLI Setup

This file assumes that you have "profiles" set up with your AWS CLI named "govcloud" and
"marketplace".   The "marketplace" account is the one that hosts Neo4j's public marketplace
presence on AWS.  And govcloud is what it sounds like.

Take note of `-c profileName` arguments and `--profile profileName` arguments.   Steps
below need to be repeated for public marketplaces and govcloud.

For `aws` commands, you need multiple profile sections in your `$HOME/.aws/config`.

For `s3cmd` commands, you need multiple config files in your `$HOME`.  For s3cmd also see [this important note](https://stanlemon.net/2013/05/23/s3cmd-and-govcloud/)

## Generate CloudFormation Template

The CloudFormation stack is a jinja template which evaluates to a CloudFormation JSON file.

Generate and copy to the right S3 bucket.  If the generate step fails due to a syntax
error, check the intermediate `generated.json` file, which contains raw jinja substitutions
before JSON parsing.

There are two possible templates you can use:
* `deploy.jinja` is for n-node causal clusters
* `deploy-standalone.jinja` is for single-node deploys

## GovCloud Support

- We will only publish Enterprise on GovCloud.  For competitive reasons, Community will be
unavailable.

### Causal clusters:

Generate from Jinja template, upload to S3, and validate.

```
# Profile should be either (marketplace|govcloud)
for value in marketplace govcloud
do
  export PROFILE=$value
  export VERSION=4.0.3
  S3BUCKET=neo4j-cloudformation
  if [ "$PROFILE" = "govcloud" ] ; then
    export S3HOST=s3-us-gov-east-1.amazonaws.com
  else 
    export S3HOST=s3.amazonaws.com
  fi
  GEN_STACK=neo4j-enterprise-stack-$VERSION.json
  pipenv run python3 generate.py \
      --edition enterprise \
      --profile $PROFILE \
      --template deploy.jinja > $GEN_STACK && \
  s3cmd -c $HOME/.s3cfg-$PROFILE -P put $GEN_STACK s3://$S3BUCKET/
  aws cloudformation validate-template \
    --template-url https://$S3HOST/$S3BUCKET/$GEN_STACK --profile $PROFILE > /dev/null
done
```

### Neo4j Enterprise Standalone:

```
for value in marketplace govcloud
do
  export PROFILE=$value
  export VERSION=4.0.3
  S3BUCKET=neo4j-cloudformation
  if [ "$PROFILE" = "govcloud" ] ; then
    export S3HOST=s3-us-gov-east-1.amazonaws.com
  else 
    export S3HOST=s3.amazonaws.com
  fi
  GEN_STACK=neo4j-enterprise-standalone-stack-$VERSION.json
  pipenv run python3 generate.py \
      --edition enterprise \
      --profile $PROFILE \
      --template deploy-standalone.jinja > $GEN_STACK && \
  s3cmd -c $HOME/.s3cfg-$PROFILE -P put $GEN_STACK s3://$S3BUCKET/
  aws cloudformation validate-template \
    --template-url https://$S3HOST/$S3BUCKET/$GEN_STACK --profile $PROFILE > /dev/null
done
```

### Neo4j Community Standalone:

```
export VERSION=4.0.3
export PROFILE=marketplace
S3BUCKET=neo4j-cloudformation
GEN_STACK=neo4j-community-standalone-stack-$VERSION.json
pipenv run python3 generate.py \
    --edition community \
    --profile $PROFILE \
    --template deploy-standalone.jinja > $GEN_STACK && \
s3cmd -c $HOME/.s3cfg-marketplace -P put $GEN_STACK s3://$S3BUCKET/
echo $GEN_STACK
aws cloudformation validate-template \
  --template-url https://s3.amazonaws.com/$S3BUCKET/$GEN_STACK --profile $PROFILE > /dev/null
```

CloudFormation can then be given the S3 URLs above

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

See the `deploy-*.sh` shell scripts.

To get the status of a stack being deployed:

```
aws cloudformation describe-stacks --stack-name $STACKNAME --region $REGION | jq -r .Stacks[0].StackStatus
```

To delete

```
aws cloudformation delete-stack --stack-name $STACKNAME --region $REGION
```