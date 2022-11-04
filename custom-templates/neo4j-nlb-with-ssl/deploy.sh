#!/bin/bash

STACK_NAME=$1
TEMPLATE_BODY="file://nlb_with_ssl.yaml"
REGION=`aws configure get region`

Password="foo123"
NumberOfServers="6"
SSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.1.0
KeyName="edr-us-east-1"
SSLDomain="neo4j.edrandall.uk"
CertificateARN="arn:aws:acm:us-east-1:540622579701:certificate/4769e182-0874-47da-8e57-398da86f5011"
aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--disable-rollback \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=GraphDatabaseVersion,ParameterValue=${GraphDatabaseVersion} \
ParameterKey=NumberOfServers,ParameterValue=${NumberOfServers} \
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False \
ParameterKey=SSLDomain,ParameterValue=${SSLDomain} \
ParameterKey=CertificateARN,ParameterValue=${CertificateARN}
