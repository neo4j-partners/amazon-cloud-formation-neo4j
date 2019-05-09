## Packer Images for Google Compute Engine
  
## Dependencies

* `brew install packer`
* Install `gcloud` cloud CLI and authenticate
* Gcloud service account JSON credentials

There is a service account there called `packer-sa` which is used
for this process.  Credentials are stored in `packer-sa.json` which isn't in
git for obvious reasons.  Gain access to the google project and grab a key, or
contact <david.allen@neo4j.com> for access.

## Build Neo4j Enterprise Image

You should specify edition (community/enterprise) and version.  Because this is
ubuntu based,versions should match what is in the debian package repo.  Watch 
out because of recent package naming, if you want v3.5.5, you need to install
`1:3.5.5`.

You may omit the AWS key variables and set them in your environment.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:3.5.5" \
    packer-template.json
```

Check the variables at the top of the JSON file for other options you can override/set.

Images go to the `launcher-development-191917` project on GCP.

## License Image and Copy to Public Project

Images above are placed in non-public project because they're in staging, also also because the public project for security reasons has no compute quota, and so images cannot be built there.

Additionally, we have to use a google-provided python script to tag
license metadata to the image in order to make it acceptable for the
launcher marketplace.  Licenses in the end aren't legal documents on GCP, they're
basically API resources that get tagged to images for tracking purposes.

Marketplace updates that are submitted, referencing non-licensed images will be rejected.

```
PACKER_IMAGE=neo4j-enterprise-1-3-5-5-apoc
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
# step builds the licensed image from the disk.  Script doesn't
# support licensing an image (the one we already created) directly.
gcloud compute instances delete $TARGET --keep-disks=all

# This step creates a new image from the disk, licenses it,
# and copies it to the destination public project.
# Path relative to packer directory.
# The disk by default gets the same name as the VM we created.
python2.7 ../partner-utils/image_creator.py --project $PROJECT --disk $TARGET \
   --name $PACKER_IMAGE --description "Neo4j Enterprise" \
   --family neo4j-enterprise \
   --destination-project $PUBLIC_PROJECT \
   --license $PUBLIC_PROJECT/neo4j-enterprise-causal-cluster

# If all of the steps above succeeded, the remaining disk leftover from
# the VM isn't needed.
gcloud compute disks delete $TARGET
```

[GCP documentation on creating licensed images](https://cloud.google.com/launcher/docs/partners/technical-components#create_the_base_solution_vm) for reference.  The scripts above encapsulate that advice though, and automate it.

## Test Public Image

See the test directory at the top of the repo for scripts which will do this.

### Check that license metadata is present.  

Note that licenses contains our entry.  Here's what good metadata looks like:

```
$ gcloud compute images describe neo4j-enterprise-1-3-4-3-apoc --project launcher-public
archiveSizeBytes: '830832128'
creationTimestamp: '2018-03-29T06:15:32.483-07:00'
description: Neo4j Enterprise
diskSizeGb: '10'
family: neo4j-enterprise
guestOsFeatures:
- type: VIRTIO_SCSI_MULTIQUEUE
id: '8597679034430740508'
kind: compute#image
labelFingerprint: 42WmSpB8rSM=
licenseCodes:
- '4948601556198734774'
- '1000201'
licenses:
- https://www.googleapis.com/compute/v1/projects/launcher-public/global/licenses/neo4j-enterprise-causal-cluster
- https://www.googleapis.com/compute/v1/projects/ubuntu-os-cloud/global/licenses/ubuntu-1604-xenial
name: neo4j-enterprise-1-3-3-4
selfLink: https://www.googleapis.com/compute/v1/projects/launcher-public/global/images/neo4j-enterprise-1-3-3-4
sourceDisk: https://www.googleapis.com/compute/v1/projects/launcher-development-191917/zones/us-east1-b/disks/license-me
sourceDiskId: '6245900834590251544'
sourceType: RAW
status: READY
```

### Create an instance of the public image in some test project:

```
gcloud compute instances create my-neo4j-instance \
    --image neo4j-enterprise-1-3-4-3 \
    --tags neo4j \
    --image-project launcher-public
```

### Test the Launcher Entry with the image

Adjust `vmImage` in `neo4j-causal-cluster.jinja` and test deploy the new setup.  This
allows testing of causal clusters with this config, with any number of nodes.