#!/bin/bash
# This script applies a google cloud license to an existing VM image, and copies
# it to the public repository of images for neo4j so that the general public can
# access it.
#
# Please read the packer/README.md about these steps before using this script.
################################################################################

PACKER_IMAGE=$1

if [ -z $PACKER_IMAGE ] ; then
    echo "Call me with the name of a packer image you want to copy/license"
    exit 1 ;
fi

PROJECT=launcher-development-191917
ZONE=us-east1-b
TARGET=license-me
PUBLIC_PROJECT=launcher-public

# Setup
gcloud config set project $PROJECT
gcloud config set compute/zone $ZONE

# Apply a google-specific license URL to the image, and then
# copy it over the public project.
license_and_copy() {
    echo "Licensing and copying image $PROJECT -> $PUBLIC_PROJECT"

    echo "Creating instance..."
    # Create image from packer instance
    gcloud --quiet compute instances create $TARGET \
    --scopes https://www.googleapis.com/auth/cloud-platform \
    --image-project $PROJECT \
    --tags neo4j \
    --image=$PACKER_IMAGE

    # Immediately delete, but keep the disk, because the next
    # step builds the licensed image from the disk.  Script doesn't
    # support licensing an image (the one we already created) directly.
    echo "Deleting licensable instance and keeping disk"
    gcloud --quiet compute instances delete $TARGET --keep-disks=all

    # This step creates a new image from the disk, licenses it,
    # and copies it to the destination public project.
    # Path relative to packer directory.
    # The disk by default gets the same name as the VM we created.
    echo "Licensing disk and creating target public image"
    python3 partner-utils/image_creator.py --project $PROJECT --disk $TARGET \
    --name $PACKER_IMAGE --description "Neo4j Enterprise" \
    --family neo4j-enterprise \
    --destination-project $PUBLIC_PROJECT \
    --license $PUBLIC_PROJECT/neo4j-enterprise-3-5-causal-cluster

    # If all of the steps above succeeded, the remaining disk leftover from
    # the VM isn't needed.
    echo "Deleting license disk/cleanup"
    gcloud --quiet compute disks delete $TARGET
}

# Community image doesn't require a license URL, just copy it.
just_copy() {
    echo "Copying image without license; $PROJECT -> $PUBLIC_PROJECT"
    gcloud compute --project="$PUBLIC_PROJECT" images create \
        "$PACKER_IMAGE" \
        --family neo4j \
        --source-image="$PACKER_IMAGE" \
        --source-image-project="$PROJECT"
}

if [[ $PACKER_IMAGE == *enterprise* ]] ; then
    license_and_copy ;
elif [[ $PACKER_IMAGE == *community* ]] ; then
    just_copy ;
else 
    echo "Unrecognized PACKER_IMAGE; not community, not enterprise"
fi

