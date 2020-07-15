# Packer Azure Templates for Neo4j

## Dependencies

* `brew install azure-cli`
* `brew install jq`

## Setup the Azure Packer Builder

Docs here: https://www.packer.io/docs/builders/azure-setup.html

You will need:

* A storage account
* An active directory service principal
* Various details including your client ID (AD SP), tenant ID, and subscription ID.

## Relevant Documentation

* [Microsoft example](https://docs.microsoft.com/en-us/azure/virtual-machines/windows/build-image-with-packer)
* [Packer examples and setup docs](https://www.packer.io/docs/builders/azure.html)

## Build Image

You should specify edition (community/enterprise) and version.  Because this is debian based,
versions should match what is in the debian package repo.

Make sure to set the env vars identified at the top of packer-template.json.

```
packer build \
    -var "neo4j_edition=enterprise" \
<<<<<<< HEAD:4.0/azure/packer/README.md
    -var "neo4j_version=1:4.0.5" \
=======
    -var "neo4j_version=1:4.1.0" \
>>>>>>> 2c0d46007beca3d30d062c8db199948c94572b4a:azure/packer/README.md
    packer-template.json
```

Check the variables at the top of the JSON file for other options you can override/set.

