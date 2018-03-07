# gcloud-launcher

This repo contains files related to cloud deployments of causal cluster.

* GCP: see the `gcloud` subdirectory
* AWS: see the `aws` subdirectory.

Tool suites in different cloud environments are very different, but there are commonalities:

- VM based deploy
- Debian-based packaging employed
- Dynamic configuration with a similar shell script (pre-neo4j.sh) which fetches metadata from the cloud provider and uses it to set environment variables inside of the VM, which are
then used to substitute a template-driven neo4j.conf that is written on every service start.

# Stress Testing

I cooked up my own script for beating up clusters just to test that they're working roughly OK.   To use that:

```
npm install
export NEO4J_USER=neo4j
export NEO4J_PASSWORD=supersecret
export NEO4J_URI=bolt+routing://my-cloud-host:7687
node stress.js
```

