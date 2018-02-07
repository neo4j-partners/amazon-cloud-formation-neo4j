# Neo4j Google Cloud Launcher

This is a default GCP Debian 9 based image, with the neo4j enterprise
package installed.  To make configuration of CC easy, a number of shell
add-ons have been installed.

# Quickstart / Deploy Instructions

A CC is deployed by creating 3 instances of the same VM, each with identical
configuration. 

```
gcloud config set project my-project-id

gcloud deployment-manager deployments create my-cluster \
    --template deployment-manager/neo4j-causal-cluster.jinja
```

# Google Image

## Source

Look for the `neo4j-cc-node-v*` images in the family `neo4j-cc` within
the development project.  **Images must be in the neo4j-cc image family**.  This property means
that when we do maintenance, we just publish a new image to that family, and the deployment
infrastructure keeps everything else up to date.

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