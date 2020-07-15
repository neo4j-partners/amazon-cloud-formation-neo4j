#!/bin/bash

if [ -z $VERSION ] ; then
   echo "You must set the VERSION env var, e.g. 3.4.11"
   exit 1
fi

export PROFILE=govcloud
export S3HOST=s3-us-gov-east-1.amazonaws.com
export BUCKET=neo4j-cloudformation
export CLUSTER_TEMPLATE=http://$S3HOST/$BUCKET/neo4j-enterprise-stack-$VERSION.json

export STACKNAME=neo4j-cloudlauncher-testdeploy-$(echo $VERSION | sed s/[^A-Za-z0-9]/-/g)
export INSTANCE=t2.large
export REGION=us-gov-east-1
export SSHKEY=bfeshti

aws cloudformation create-stack \
   --stack-name $STACKNAME \
   --region $REGION \
   --template-url $CLUSTER_TEMPLATE \
   --parameters ParameterKey=ClusterNodes,ParameterValue=3 \
                ParameterKey=InstanceType,ParameterValue=$INSTANCE \
                ParameterKey=NetworkWhitelist,ParameterValue=0.0.0.0/0 \
                ParameterKey=Password,ParameterValue=s00pers3cret \
                ParameterKey=SSHKeyName,ParameterValue=$SSHKEY \
                ParameterKey=VolumeSizeGB,ParameterValue=37 \
                ParameterKey=VolumeType,ParameterValue=gp2 \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile govcloud

