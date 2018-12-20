# Packer Azure Templates for Neo4j

## Dependencies

* `brew install azure-cli`

## Relevant Documentation

* [Microsoft example](https://docs.microsoft.com/en-us/azure/virtual-machines/windows/build-image-with-packer)
* [Packer examples and setup docs](https://www.packer.io/docs/builders/azure.html)

## Build Image

You should specify edition (community/enterprise) and version.  Because this is debian based,
versions should match what is in the debian package repo.

You may omit the AWS key variables and set them in your environment.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:3.5.1" \
    packer-template.json
```

Check the variables at the top of the JSON file for other options you can override/set.

