#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j.template2.yaml"
REGION=`aws configure get region`
BUCKET_NAME="harshit-cft"

Password="foo123"
#KeyName="neo4j-${REGION}"
KeyName="harshit"
NodeCount="3"
SSHCIDR="0.0.0.0/0"
VPCCIDR="10.0.0.0/16"
SubnetCIDR="10.0.1.0/24"
SelectSSR='True'


aws cloudformation package --template-file neo4j.template2.yaml --output-template neo4j_cft.yaml --s3-bucket ${BUCKET_NAME}

aws cloudformation deploy \
--template-file neo4j_cft.yaml \
--stack-name ${STACK_NAME} \
--capabilities CAPABILITY_IAM \
--parameter-overrides \
Password=${Password} \
KeyName=${KeyName} \
NodeCount=${NodeCount} \
SSHCIDR=${SSHCIDR} \
VPCCIDR=${VPCCIDR} \
SubnetCIDR=${SubnetCIDR} \
InstallGraphDataScience=False \
InstallBloom=False \
SelectSSR=${SelectSSR}
