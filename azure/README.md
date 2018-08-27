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

## Jinja Templating

Because the ARM templating language is flat JSON, the code in flat JSON is very much not DRY.
Jinja templating is used (as with the other cloud hosting providers) to abstract away some
bits.  This also means that the generate python script must be used to expand the template into
the JSON that is seen by ARM.

This process works similar to the way the Amazon templates works:

```
pipenv run python3 generate.py --template somefile.json.jinja > somefile.json
```

This command expands the template and saves the resulting JSON.  As part of the create script,
this process is run on all of the jinja templates to prepare them for upload to S3, and
interpretation by Azure ARM.

## Relevant Documentation

- [Azure Resource Manager Documentation](https://docs.microsoft.com/en-us/azure/azure-resource-manager/)
