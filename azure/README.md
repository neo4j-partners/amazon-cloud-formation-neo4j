# Azure Deployment of Neo4j

## POCs and People

* Technical: Brian Moore bmoore@microsoft.com
* Partnering: Patrick Butler Monterde Patrick.Butler@microsoft.com

## Partnering Site

Use the [Azure Cloud Partner Site](https://cloudpartner.azure.com/#alloffers) to work with Azure "offers".  The way this is structured there is that there is a VM-based offering (for the packer-built VM) and a second Azure Application offering for Causal Cluster, which is a set of ARM templates that use the VM.

Each offering comes with marketing metadata, screenshots, video links, and other supporting materials for Neo4j's public presence.

## Layout

- `packer` builds source images on azure
- `arm` contains Azure Resource Manager templates to assemble deployments
- `bin` contains sample scripts necessary for testing/launching/deleting

## Approach

The way Azure works in the marketplace is as follows:

1. Neo4j offers a VM-only solution (standalone)
2. Neo4j offers an ARM template based cluster solution, based on that VM solution.

That's the outcome.  The process to get there:

1. Build VMs with Packer (`packer` subdir, see README)
2. Follow VM prep instructions below, to arrive at the VM-based solution in the partner
portal. (instructions later in this file)
3. Prep the ARM templates
4. Update the ARM package under the "Causal Cluster" solution in the partner portal.

## History

Much of the code in this repo is based off of an earlier approach found in [this repo](https://github.com/neo4j/azure-neo4j).  The contribution here is to update Neo4j to a modern version, switch to CC instead of HA, and help automate image creation with packer so that we can keep things current moving forward, and manage it using roughly the same approach as is used for Google and AWS.

Extensive changes have been made to that first approach, because it used a number of 
outdated Azure approaches, it didn't use pre-prepared VMs, and was HA-only.  That
repo also contains huge optionality which makes it very hard to test, and feedback from
the field was that 20% of deployments failed with errors, likely due to poor testing.

Because we're basing the offering on another VM offering, we get several benefits:
1. Faster startup time (because you don't have to install/configure neo4j on launch)
2. More likely success (because extra steps we're skipping can't fail due to network or publishing issues).  The old offering could fail deployment for example if our debian repo had momentary issues.
3. Better code modularity (there's what goes into the VM, and how the VM is composed into a cluster, kept as separate issues)
4. Mirroring the AWS and google approach (they both use packer + deployment templates)

## Running a Local Deploy

Run `bin/create`.  This creates a local set of properties equivalent to what a user would choose in a GUI, copies all of the latest development templates to the S3 hosting bucket, and
uses the `bin/deploy` script to create an azure deployment from those parameters and templates.

## Prepping VMs

Packer leaves us with a not great decision.

- Use packer to generate VHDs.  This approach is deprecated, but generates the VHD
that is necessary for the VM-based marketplace offering
- Use packer to generate managed images.  These are recommended, and easier to work
with, but are hard to get a VHD out of and aren't supported by the partner marketplace.

I've opted to engineer the packer approach to produce VHDs.   Docs are available online
on how to reverse engineer a VHD out of a packer managed image, but this doesn't appear
to be worth it because of the modifications to the packer build process it requires.

To specify the VHD as the source for a marketplace VM offering, you have to generate
a SAS URL (temporary time gated access to a storage resource).  This can be done with
the Azure Storage Explorer.

If all of that sounds complex and confusing...that's because it is.

Once a VHD is produced by packer, you have to generate a SAS URL to the VHD, which is what you need
to update the marketplace.  Guidance on generating the SAS URL can be found here:

https://docs.microsoft.com/en-us/azure/marketplace-publishing/marketplace-publishing-vm-image-creation#52-get-the-shared-access-signature-uri-for-your-vm-images

I use the Microsoft Storage Explorer tool to generate it.

## Best Practices for Packaging (ARM)

https://github.com/Azure/azure-quickstart-templates/blob/master/1-CONTRIBUTION-GUIDE/best-practices.md#deployment-artifacts-nested-templates-scripts

## ARM Template Storage

Stored in an Amazon S3 bucket called 'neo4j-arm', hosted here: `https://s3.amazonaws.com/neo4j-arm/arm/`.  This is because ArtifactsBase, a required parameter,
requires a fully-qualified public URL in order to resolve other files that belong.

Two directories test and arm correspond to local dev testing and finished deployed version.

## Deploying Public Templates

To publish ARM templates, we want to copy them into a directory structure on the S3 bucket once
they're prepped.  This public S3 bucket allows customers to deploy as needed, and get access to
the code to customize deployments for their setups.

Verify first that the templates are working with the bin/create script (which does jinja expansion)
and then copy them like so:

```
export VERSION=3.5.11
s3cmd put --recursive -P arm/* s3://neo4j-arm/$VERSION/causal-cluster/
```

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

## Updating ARM templates for new versions

In the neo4j node set jinja templates, the "plan" object must be updated with details of the new
offer, and the "imageReference" under storage profile as well.  

In the marketplace portal, Offer IDs, Publisher IDs, names, and SKUs can be used to complete these fields.

While it is possible to test the cluster templates against a local image, it requires changing the structure of the template just a bit as documented in that jinja template.  In general it's easier to 
test and deploy the baseline image as a stand-alone product first, and then to test the cluster templates against the published marketplace stand-alone image to eliminate things which could go wrong in coordinating two different publish steps.

Once the new VM image is published to the marketplace, before it can be programmatically deployed you
have to accept legal terms.  Here's how to do that.

Find the URN of the image:

```
az vm image list --all --publisher neo4j --offer neo4j-enterprise-3_5 --query '[].urn'
```

Then grab that URN and accept terms of it:

```
$ az vm image accept-terms --urn neo4j:neo4j-enterprise-3_5:neo4j_3_5_5_apoc:3.5.5
{
  "accepted": true,
  "id": "/subscriptions/e4486a99-00d6-4e46-aab0-b087f918eda9/providers/Microsoft.MarketplaceOrdering/offerTypes/Microsoft.MarketplaceOrdering/offertypes/publishers/neo4j/offers/neo4j-enterprise-3_5/plans/neo4j_3_5_11_apoc/agreements/current",
  "licenseTextLink": "https://storelegalterms.blob.core.windows.net/legalterms/3E5ED_legalterms_NEO4J%253a24NEO4J%253a2DENTERPRISE%253a2D3%253a5F5%253a24NEO4J%253a5F3%253a5F5%253a5F1%253a5FAPOC%253a246B7QTJUDYN6IZQG4Y3VB33CWFLLCG3UGG7D2MIVE4PWNDHNYELSYU66EVZTSTHSFNRIATQXPV75ARRST64F6GK35S73HJKZL5H42P2Y.txt",
  "name": "neo4j_3_5_11_apoc",
  "plan": "neo4j_3_5_11_apoc",
  "privacyPolicyLink": "https://neo4j.com/privacy-policy/",
  "product": "neo4j-enterprise-3_5",
  "publisher": "neo4j",
  "retrieveDatetime": "2019-01-04T13:07:09.8321069Z",
  "signature": "UG4V7654Q2BDFQUDHLJR73Y2QFAUG2UGCBLEPYPZ5HS3LWJ4WMOXTD2NQME2QNM3T7J3YIYFJ2F75FEWKFHLR2ATXAJUWYXDK3IDJEA",
  "type": "Microsoft.MarketplaceOrdering/offertypes"
}
```

ARM deployments can now work against that published VM.

The relevant bits of the ARM:

```
			"imageReference": {
                "publisher": "neo4j",
                "offer": "neo4j-enterprise-3_5",
                "sku": "neo4j_3_5_11_apoc",
                "version": "latest"
			},
```

and

```
    "plan": {
        "name": "neo4j_3_5_11_apoc",
        "publisher": "neo4j",
        "product": "neo4j-enterprise-3_5"
    },
```

## Packaging the ARM Templates for the Marketplace

They just need to be zipped into a ZIP file and submitted to the marketplace
UI.  See the `package.sh` script in the arm directory to package the right
files in the right format, and upload the ZIP that results from that script.

## Relevant Documentation

- [Azure Resource Manager Documentation](https://docs.microsoft.com/en-us/azure/azure-resource-manager/)
