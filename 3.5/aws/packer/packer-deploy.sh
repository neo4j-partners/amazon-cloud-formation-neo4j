#!/bin/bash
if [[ $ENVIRONMENT == "PROD" ]]; then
export PROFILE=marketplace
export VERSION=3.5.21
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:3.5.21" \
    packer-template.json

packer build \
    -var "neo4j_edition=community" \
    -var "neo4j_version=1:3.5.21" \
    packer-template.json

elif [[ $ENVIRONMENT == "TEST" ]]; then
  export PROFILE=marketplace
export VERSION=3.5.21
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:3.5.21" \
    packer-template-test.json

packer build \
    -var "neo4j_edition=community" \
    -var "neo4j_version=1:3.5.21" \
    packer-template-test.json
else
   echo "Parameter: $ENVIRONMENT is not valid"
fi
#export PROFILE=govcloud
#export AWS_PROFILE=govcloud
#packer build \
#    -var "neo4j_edition=enterprise" \
#    -var "neo4j_version=1:3.5.21" \
#    -var "region=us-gov-east-1" \
#    -var "destination_regions=us-gov-west-1" \
#    -var "instance_type=t3.micro" \
#    -var "base_owner=513442679011" \
#    packer-template.json