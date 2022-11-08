#!/bin/bash

STACK_NAME=$1
TEMPLATE_BODY="file://alb_with_ssl.yaml"
REGION=$(aws configure get region)

Password="foo123"
NumberOfServers="3"
SSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.1.0
KeyName="edr-us-east-1"
SSLDomain="neo4j.edrandall.uk"
CertificateARN="arn:aws:acm:us-east-1:540622579701:certificate/fbb5441f-4076-42a1-80e2-6ba065a8eaff"
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
ParameterKey=CertificateARN,ParameterValue=${CertificateARN} \
ParameterKey=KeyName,ParameterValue=${KeyName}

