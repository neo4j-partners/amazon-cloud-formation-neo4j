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
