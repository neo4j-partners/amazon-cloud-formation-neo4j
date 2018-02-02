# gcloud-launcher

How this works: there is a Debian 9 based VM provided by google, with enterprise installed.
To configure CC, a small modification has been made to /etc/init.d/neo4j which checks google
environment variables, and customizes neo4j.conf at startup time, with the appropriate dynamic IPs.

Place `pre-neo4j.sh` into `/etc/init.d` on the VM, then edit `/etc/init.d/neo4j` so that the startup
function calls this external script.

**Be aware that this step may require repetition when updating the version, as upgrading the 
enterprise dpkg may change /etc/init.d/neo4j**

# Neo4j Config Template Substitution

This git repo's `neo4j.conf` should be placed in `/etc/neo4j/neo4j.template`.   It contains environment
variables that get substituted by `pre-neo4j.sh` to yield the final correct config.

