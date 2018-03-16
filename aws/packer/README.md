# Packer AMI Templates for Neo4j

## Dependencies

* `brew install packer`

## Build Neo4j Enterprise AMI

You should specify edition (community/enterprise) and version.  Because this is debian based,
versions should match what is in the debian package repo.

You may omit the AWS key variables and set them in your environment.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:3.3.4" \
    packer-AMI-template.json
```

Check the variables at the top of the JSON file for other options you can override/set.

## Making them Public

In the packer template, the `ami_groups` setting does this.  Because we're still testing, this hasn't been done yet.

[AMI Groups Documentation](https://www.packer.io/docs/builders/amazon-ebs.html#ami_groups)