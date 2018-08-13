# Azure Deployment of Neo4j

## Layout

- `packer` builds source images on azure
- `arm` contains Azure Resource Manager templates to assemble deployments
- `bin` contains sample scripts necessary for testing/launching/deleting

## Background

Much of the code in this repo is based off of an earlier approach found in [this repo](https://github.com/neo4j/azure-neo4j).  The contribution here is to update Neo4j to a modern version, switch to CC instead of HA, and help automate image creation with packer so that we can keep things current moving forward, and manage it using roughly the same approach as is used for Google and AWS.

## Running a Local Deploy

Run `bin/create`.  This creates a local set of properties equivalent to what a user would choose in a GUI, copies all of the latest development templates to the S3 hosting bucket, and
uses the `bin/deploy` script to create an azure deployment from those parameters and templates.

## ARM Template Storage

Stored in an Amazon S3 bucket called 'neo4j-arm', hosted here: `https://s3.amazonaws.com/neo4j-arm/arm/`.  This is because ArtifactsBase, a required parameter,
requires a fully-qualified public URL in order to resolve other files that belong.

Two directories test and arm correspond to local dev testing and finished deployed version.

## Relevant Documentation

- [Azure Resource Manager Documentation](https://docs.microsoft.com/en-us/azure/azure-resource-manager/)
