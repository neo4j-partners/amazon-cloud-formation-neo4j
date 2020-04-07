#!/bin/bash

if [ -z $VERSION ] ; then
   echo "You must set the VERSION env var, e.g. 4.0.2"
   exit 1
fi

export COMMUNITY_TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-community-standalone-stack-$VERSION.json

export STACKNAME=neo4j-community-testdeploy-$(echo $VERSION | sed s/[^A-Za-z0-9]/-/g)
export INSTANCE=r4.large
export REGION=us-east-1
export SSHKEY=bfeshti

aws cloudformation create-stack \
   --stack-name $STACKNAME \
   --region $REGION \
   --template-url $COMMUNITY_TEMPLATE \
   --parameters ParameterKey=InstanceType,ParameterValue=$INSTANCE \
                ParameterKey=NetworkWhitelist,ParameterValue=0.0.0.0/0 \
                ParameterKey=Password,ParameterValue=s00pers3cret \
                ParameterKey=SSHKeyName,ParameterValue=$SSHKEY \
                ParameterKey=VolumeSizeGB,ParameterValue=37 \
                ParameterKey=VolumeType,ParameterValue=gp2 \
  --capabilities CAPABILITY_NAMED_IAM

