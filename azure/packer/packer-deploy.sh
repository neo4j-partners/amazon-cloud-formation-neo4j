#!/bin/bash

<<<<<<< HEAD:azure/packer/packer-deploy.sh
export VERSION=4.3.0
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:4.3.0" \
=======
export VERSION=4.3.2
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:4.3.2" \
>>>>>>> neo4j-v4.3.0:4.2/gcloud/packer/packer-deploy.sh
    packer-template.json

packer build \
    -var "neo4j_edition=community" \
<<<<<<< HEAD:azure/packer/packer-deploy.sh
    -var "neo4j_version=1:4.3.0" \
=======
    -var "neo4j_version=1:4.3.2" \
>>>>>>> neo4j-v4.3.0:4.2/gcloud/packer/packer-deploy.sh
    packer-template.json

#export PROFILE=govcloud
#export AWS_PROFILE=govcloud
#packer build \
#    -var "neo4j_edition=enterprise" \
<<<<<<< HEAD:azure/packer/packer-deploy.sh
#    -var "neo4j_version=1:4.3.0" \
=======
#    -var "neo4j_version=1:4.3.2" \
>>>>>>> neo4j-v4.3.0:4.2/gcloud/packer/packer-deploy.sh
#    -var "region=us-gov-east-1" \
#    -var "destination_regions=us-gov-west-1" \
#    -var "instance_type=t3.micro" \
#    -var "base_owner=513442679011" \
#    packer-template-test.json