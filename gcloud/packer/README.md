## Packer Images for Google Compute Engine
  
## Dependencies

* `brew install packer`
* Install `gcloud` cloud CLI and authenticate

## Build Neo4j Enterprise Image

You should specify edition (community/enterprise) and version.  Because this is ubuntu based,
versions should match what is in the debian package repo.  Watch out because of recent
package naming, if you want v3.3.4, you need to install `1:3.3.4`.

You may omit the AWS key variables and set them in your environment.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:3.3.4" \
    packer-template.json
```

Check the variables at the top of the JSON file for other options you can override/set.

Images go to the `launcher-development-191917` project on GCP.

There is a service account there called `packer-sa` which is used
for this process.

## Copy Images to Public Project

Images above are placed in non-public project because they're in staging, also also because the public project for security reasons has no compute quota, and so images cannot be built there.

Additionally, we have to use a google-provided python script to tag
license metadata to the image in order to make it acceptable for the
launcher marketplace.

```
PACKER_IMAGE=neo4j-enterprise-1-3-3-4
PROJECT=launcher-development-191917
ZONE=us-east1-b
TARGET=license-me
PUBLIC_PROJECT=launcher-public

# Setup
gcloud config set project $PROJECT
gcloud config set compute/zone $ZONE

# Create image from packer instance
gcloud compute instances create $TARGET \
   --scopes https://www.googleapis.com/auth/cloud-platform \
   --image-project $PROJECT \
   --tags neo4j \
   --image=$PACKER_IMAGE

# Immediately delete, but keep the disk, because the next
# step needs the disk.
gcloud compute instances delete $TARGET --keep-disks=all

# This step creates a new image from the disk, licenses it,
# and copies it to the destination public project.
# Path relative to packer directory.
python2.7 ../partner-utils/image_creator.py --project $PROJECT --disk $TARGET \
   --name $PACKER_IMAGE --description "Neo4j Enterprise" \
   --destination-project $PUBLIC_PROJECT \
   --license $PUBLIC_PROJECT/neo4j-enterprise-causal-cluster
```

## Test Public Image

Create an instance of the public image in some test project:

```
gcloud compute instances create my-neo4j-instance \
    --image neo4j-enterprise-1-3-3-4 \
    --tags neo4j \
    --image-project launcher-public
```