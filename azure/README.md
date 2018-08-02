# Azure Deployment of Neo4j

## Layout

- `packer` builds source images on azure
- `arm` contains Azure Resource Manager templates to assemble deployments
- `bin` contains sample scripts necessary for testing/launching/deleting

## Background

Much of the code in this repo is based off of an earlier approach found in [this repo](https://github.com/neo4j/azure-neo4j).  The contribution here is to update Neo4j to a modern version, switch to CC instead of HA, and help automate image creation with packer so that we can keep things current moving forward, and manage it using roughly the same approach as is used for Google and AWS.

## Relevant Documentation

- [Azure Resource Manager Documentation](https://docs.microsoft.com/en-us/azure/azure-resource-manager/)
