# Neo4j Google Cloud Launcher

This is a default GCP Debian 9 based image, with the neo4j enterprise
package installed.  To make configuration of CC easy, a number of shell
add-ons have been installed.

# GCloud API Requirements

```
gcloud services enable runtimeconfig.googleapis.com
gcloud services enable compute.googleapis.com
gcloud services enable deploymentmanager.googleapis.com
```

# Quickstart / Deploy Instructions

A CC is deployed by creating 3 instances of the same VM, each with identical
configuration. 

```
gcloud config set project my-project-id

gcloud deployment-manager deployments create my-cluster \
    --template deployment-manager/neo4j-causal-cluster.jinja
```

# A Warning

Google's launcher documentation isn't great in spots, and there are a bunch of small
WTFs.  Our technical POC was Emily Bates <emilybates@google.com> who was super helpful,
and can answer technical questions.

# Important Deployment Files

- `neo4j-causal-cluster.jinja` is the entrypoint for how a cluster gets deployed.
- `neo4j-causal-cluster.jinja.display` contains instructions to Google's Launcher app on how to lay out the UI, what users can pick, etc.
- `neo4j-causal-cluster.jinja.schema` contains the visual elements users get asked to provide, plus defines inputs/outputs for the entire deploy process.  This is also where you do things like specify options for how many nodes could be deployed, set a minimum machine type, etc.

# Preparing a new Image (i.e. upgrading all of this)

- Inside of the running image you're creating, make sure neo4j password is set to `admin`
because the startup script in deployment manager expects this when changing to random
strong password.
- [Prepare the image like this](https://cloud.google.com/launcher/docs/partners/technical-components#create_the_base_solution_vm).
- Update the image you want to use in several places: `c2d_deployment_configuration.json`, 
and the main solution jinja template.   Google does not support "in place updates", so you
cannot replace the existing VM without changing the deployment template.

Crucial step with partner tools to create new image:

```
   $ python2.7 image_creator.py --project launcher-development-191917 \
      --disk my-cluster-vm-1 \
      --name neo4j-cc-3-3-3-vWHATEVER \
      --description "Neo4j Enterprise 3.3.3 Causal Cluster" \
      --destination-project launcher-public \
      --license launcher-public/neo4j-enterprise-causal-cluster
```

# Removing a Deployment

Removing the deployment autokills/deletes the underlying VMs.
**But not their disks** since we've marked the disks to be persistent
by default.

Note the disk delete statement here is risky, make sure you don't have
clashing named disks.  This is quick instruction only, take care when
deleting disks.

```
# Kill/delete VMs.
gcloud deployment-manager deployments delete my-cluster

# Remove persistent disks.
for disk in `gcloud compute disks list --filter="name:my-cluster-vm-*" --format="get(name)"` ; do 
  gcloud compute disks delete "$disk" ; 
done
```

# Google Image

## Source

Look for the `neo4j-cc-node-v*` images in the family `neo4j-cc` within
the development project.  In the public project, there are corresponding "live"
images.

## Metadata

Google deploy manager jinja templates allow us to configure key/values on the image.  This metadata in turn can be fetched inside of the VM from a metadata server.

The `/etc/neo4j/neo4j.template` file controls how image metadata impacts neo4j server configuration.  Prior to neo4j starting up, these values are fetched from google's metadata server, and substituted into neo4j.conf via the template.   See `pre-neo4j.sh` for the mechanics of how this works.

Only a limited number of necessary options are configurable now, the rest
is TODO.

The result of all of this is that by tweaking the deployment manager
template, you can control the entire cluster's identical config.

# What to do when upgrading Neo4j

When installing a new neo4j package, the main thing is to ensure that the service hook continues to run pre-neo4j.sh.  See the section below on 
debian instance service configuration.  All other updates should be automatic, presuming no internal neo4j configuration settings change.

# Debian Instance Service Configuration

The image is based on Debian 9, and the standard neo4j debian package, so you should be using `systemctl` inside of the VM.

[Relevant docs](https://www.digitalocean.com/community/tutorials/how-to-use-systemctl-to-manage-systemd-services-and-units)

Status can be obtained via `systemctl status neo4j.service`

Normally, the command for the neo4j service is `neo4j console`.  That has been placed in pre-neo4j.sh.

Make sure also that `/usr/share/neo4j/conf/neo4j.conf` is a symlink to `/etc/neo4j/neo4j.conf`

So the system service profile (`systemctl edit --full neo4j.service`) instead calls `pre-neo4j.sh`.   This part is critical to be maintained between service maintenance and package upgrades.

# Limitations and TODO

## Network Locality

Currently, all node instances must be deployed in the same subnet, same zone/region on GCP.
This is because they find each other by local and GCP internal DNS name resolution. This can
be overcome if you set up separate DNS or static IP addresses for new nodes, and then ensure
that the `causal_clustering_initial_discovery_members` metadata setting contains the right hosts.

## Cluster Size

The deployment manager templates are going to be wired to deploy 3 nodes.  Because things are 
configurable from the outside though, it should be straightforward to deploy any size or topology,
because you can pass dbms.MODE, expected cluster size, initial cluster members, and so on in from
the outside with metadata.

Yet uncertain, whether google provides tools to build GUIs to solicit these parameters and then
use those in the template.