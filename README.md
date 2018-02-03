# gcloud-launcher

How this works: there is a Debian 9 based VM provided by google, with enterprise installed.
To configure CC, a small modification has been made to /etc/init.d/neo4j which checks google
environment variables, and customizes neo4j.conf at startup time, with the appropriate dynamic IPs.

Use the `install-to.sh` script to place the right files in the right places on the target VM.

**Be aware that this step may require repetition when updating the version, as upgrading the 
enterprise dpkg may change /etc/init.d/neo4j**

# Neo4j Config Template Substitution

This git repo's `neo4j.conf` should be placed in `/etc/neo4j/neo4j.template`.   It contains environment
variables that get substituted by `pre-neo4j.sh` to yield the final correct config.

# Debian Instance Service Configuration

Image is based on Debian 9, so you should be using `systemctl` inside of the VM.

[Relevant docs](https://www.digitalocean.com/community/tutorials/how-to-use-systemctl-to-manage-systemd-services-and-units)

Status can be obtained via `systemctl status neo4j.service`

Normally, the command for the neo4j service is `neo4j console`.  That has been placed in pre-neo4j.sh.
So the system service profile (`systemctl edit --full neo4j.service`) instead calls pre-neo4j.sh
