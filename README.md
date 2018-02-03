# Neo4j Google Cloud Launcher

This is a default GCP Debian 9 based image, with the neo4j enterprise
package installed.  To make configuration of CC easy, a number of shell
add-ons have been installed.

# Google Image Metadata

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
