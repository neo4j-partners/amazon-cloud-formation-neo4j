# Packer AMI Templates for Neo4j

## Dependencies

* `brew install packer`
* marketplaces@neo4j.com credentials.  David Allen, Kurt Freytag, and Ryan Boyd have them.

## Build Neo4j Enterprise AMI

You should specify edition (community/enterprise) and version.  Because this is debian based,
versions should match what is in the debian package repo.

You may omit the AWS key variables and set them in your environment.

**Double check your environment before beginning**.   We start to publish for both marketplaces,
and GovCloud, which requires a different keyset.  Region also differs for GovCloud.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:4.3.6" \
    packer-template.json
```

## Build for GovCloud

The process is the same as building for the regular AWS marketplace.  The differences are: 
* the region you build in, 
* the destination regions you copy to, 
* the ID of the account which owns the base Ubuntu image
* Instance type to build on, default t2.micro isn't available on govcloud.

The defaults in the template are set up for marketplaces. Here is a working example for GovCloud.

Note that the ID of the base_owner is just something you have to look up in GovCloud to see who is
the legit publisher of Ubuntu images there.  This is the same *entity* as the publisher on 
public AWS, but they have a different account ID on GovCloud.

```
packer build \
    -var "neo4j_edition=enterprise" \
    -var "neo4j_version=1:4.3.6" \
    -var "region=us-gov-east-1" \
    -var "destination_regions=us-gov-west-1" \
    -var "instance_type=t3.micro" \
    -var "base_owner=513442679011" \
    packer-template.json
```

Check the variables at the top of the JSON file for other options you can override/set.

## Making them Public

In the packer template, the `ami_groups` setting does this.

[AMI Groups Documentation](https://www.packer.io/docs/builders/amazon-ebs.html#ami_groups)

Note that you should use credentials for marketplaces@neo4j.com to build the AMIs, so they are visible
via the [Marketplaces AMI Manager](https://aws.amazon.com/marketplace/management/manage-products/?#/manage-amis.unshared).

