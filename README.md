# neo4j-cloud-launcher

There is one folder per supported cloud platform.  Underneath of those,
you can find a `packer` folder for building images on that platform, and
a set of templates for deploying neo4j images.  The template language is
of course cloud specific.

Commonalities between cloud environments are things we try to exploit
to do things once:

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

# Credentials, Questions

To use some of this stuff, you'll need service account credentials.
David Allen <david.allen@neo4j.com> has those.