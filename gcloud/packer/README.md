## Packer Images for Google Compute Engine
  
## Dependencies

* `brew install packer`
* Install `gcloud` cloud CLI and authenticate

## Build Neo4j Enterprise Image

You should specify edition (community/enterprise) and version.  Because this is ubuntu based,
versions should match what is in the debian package repo.  Watch out because of recent
package naming, if you want v3.3.3, you need to install `1:3.3.3`.

You may omit the AWS key variables and set them in your environment.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:3.3.3" \
    packer-template.json
```

Check the variables at the top of the JSON file for other options you can override/set.

Images go to the `launcher-development-191917` project on GCP.

There is a service account there called `packer-sa` which is used
for this process.

## Copy Images to Public Project

Images above are placed in non-public project because they're in staging, also also because the public project for security reasons has no compute quota, and so images cannot be built there.

```
PACKER_IMAGE=neo4j-enterprise-1-3-3-3
gcloud compute --project=launcher-public images create $PACKER_IMAGE --source-image=$PACKER_IMAGE --source-image-project=launcher-development-191917
```

## Test Public Image

Create an instance of the public image in some test project:

```
gcloud compute instances create my-neo4j-instance \
    --image neo4j-enterprise-1-3-3-3 \
    --image-project launcher-public
```