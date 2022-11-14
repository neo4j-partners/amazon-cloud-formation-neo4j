#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j-nlb-priv-ssl.template.yaml"
REGION=$(aws configure get region)

Password="foo123"
NumberOfServers="3"
BastionSSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.1.0
SSHKeyName="EdTest-us-east-1"

#Update with your SSLDomain
SSLDomain="neo4j.edrandall.uk"

#Update with the ARN of the Certificate from AWS Certificate Manager
CertificateARN="arn:aws:acm:us-east-1:540622579701:certificate/d2660ecc-dc23-4984-8198-38f4f0b07a1b"

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
ParameterKey=BastionSSHCIDR,ParameterValue=${BastionSSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False \
ParameterKey=SSHKeyName,ParameterValue=${SSHKeyName} \
ParameterKey=SSLDomain,ParameterValue=${SSLDomain} \
ParameterKey=CertificateARN,ParameterValue=${CertificateARN}