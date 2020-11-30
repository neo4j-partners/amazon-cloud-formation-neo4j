#!/bin/bash

if [ -z $VERSION ] ; then
   echo "You must set the VERSION env var, e.g. 4.2.0"
   exit 1
fi
if [[ $DEPLOYMENT_TYPE == "CLUSTER" ]]; then
  export SINGLE_TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-enterprise-standalone-stack-$VERSION.json
  export CLUSTER_TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-enterprise-stack-$VERSION.json
  export COMMUNITY_TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-community-standalone-stack-$VERSION.json

  export STACKNAME=neo4j-cloudlauncher-testdeploy-$(echo $VERSION | sed s/[^A-Za-z0-9]/-/g)
  export INSTANCE=r4.large
  export REGION=us-east-1
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
    --capabilities CAPABILITY_NAMED_IAM

elif [[ $DEPLOYMENT_TYPE == "CLUSTER-GOVCLOUD" ]]; then
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

elif [[ $DEPLOYMENT_TYPE == "GOVCLOUD-STANDALONE" ]]; then
  export PROFILE=govcloud
  export S3HOST=s3-us-gov-east-1.amazonaws.com
  export BUCKET=neo4j-cloudformation
  export SINGLE_TEMPLATE=http://$S3HOST/$BUCKET/neo4j-enterprise-standalone-stack-$VERSION.json

  export STACKNAME=neo4j-single-testdeploy-$(echo $VERSION | sed s/[^A-Za-z0-9]/-/g)
  export INSTANCE=t2.large
  export REGION=us-gov-east-1
  export SSHKEY=bfeshti

  aws cloudformation create-stack \
     --stack-name $STACKNAME \
     --region $REGION \
     --template-url $SINGLE_TEMPLATE \
     --parameters ParameterKey=InstanceType,ParameterValue=$INSTANCE \
                  ParameterKey=NetworkWhitelist,ParameterValue=0.0.0.0/0 \
                  ParameterKey=Password,ParameterValue=s00pers3cret \
                  ParameterKey=SSHKeyName,ParameterValue=$SSHKEY \
                  ParameterKey=VolumeSizeGB,ParameterValue=37 \
                  ParameterKey=VolumeType,ParameterValue=gp2 \
    --capabilities CAPABILITY_NAMED_IAM \
    --profile govcloud

elif [[ $DEPLOYMENT_TYPE == "COMMUNITY" ]]; then
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

elif [[ $DEPLOYMENT_TYPE == "STANDALONE" ]]; then
  export SINGLE_TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-enterprise-standalone-stack-$VERSION.json

  export STACKNAME=neo4j-single-testdeploy-$(echo $VERSION | sed s/[^A-Za-z0-9]/-/g)
  export INSTANCE=r4.large
  export REGION=us-east-1
  export SSHKEY=bfeshti

  aws cloudformation create-stack \
     --stack-name $STACKNAME \
     --region $REGION \
     --template-url $SINGLE_TEMPLATE \
     --parameters ParameterKey=InstanceType,ParameterValue=$INSTANCE \
                  ParameterKey=NetworkWhitelist,ParameterValue=0.0.0.0/0 \
                  ParameterKey=Password,ParameterValue=s00pers3cret \
                  ParameterKey=SSHKeyName,ParameterValue=$SSHKEY \
                  ParameterKey=VolumeSizeGB,ParameterValue=37 \
                  ParameterKey=VolumeType,ParameterValue=gp2 \
    --capabilities CAPABILITY_NAMED_IAM
else
   echo "Provider: $DEPLOYMENT_TYPE is not valid"
fi