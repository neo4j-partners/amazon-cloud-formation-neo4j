# Proposal: Neo4j Community Edition CloudFormation Template

This document proposes the creation of a CloudFormation template for deploying Neo4j Community Edition (CE) on AWS. It explains what Community Edition is, how it differs from the existing Enterprise Edition (EE) template in this repository, what the CE template should contain, and the best practices from the Neo4j Operations Manual that inform the design.

---

## Table of Contents

1. [What is Neo4j Community Edition?](#what-is-neo4j-community-edition)
2. [Why Offer a CE Template?](#why-offer-a-ce-template)
3. [CE vs EE: Key Differences](#ce-vs-ee-key-differences)
4. [What Changes From the Existing EE Template](#what-changes-from-the-existing-ee-template)
5. [Proposed CE Template Design](#proposed-ce-template-design)
6. [Best Practices From the Neo4j Operations Manual](#best-practices-from-the-neo4j-operations-manual)
7. [Implementation Plan](#implementation-plan)
8. [Open Questions](#open-questions)
9. [References](#references)

---

## What is Neo4j Community Edition?

Neo4j Community Edition is the free, open-source version of Neo4j released under the GPLv3 license. It provides the same core graph database engine as Enterprise Edition, including:

- The native graph storage engine with ACID-compliant transactions
- The Cypher query language for querying and updating graph data
- Neo4j Browser for visualization and interactive queries
- Bolt and HTTP protocol connectors for client access
- The APOC (Awesome Procedures on Cypher) library for extended functionality

Community Edition is designed for single-instance deployments. It is well-suited for development, prototyping, learning, small workgroups, and production applications that do not require clustering, advanced security, or online backup capabilities.

The package name on Linux is `neo4j` (as opposed to `neo4j-enterprise` for EE), and it does not require accepting a commercial license agreement during installation.

---

## Why Offer a CE Template?

The existing repository only provides a CloudFormation template for Enterprise Edition via the AWS Marketplace. A Community Edition template serves a different audience and fills a gap:

1. **Cost sensitivity** - CE is free. Many developers, startups, and small teams want to run Neo4j on AWS without Enterprise licensing costs. An EE deployment requires a commercial license that can be expensive for smaller organizations.

2. **Simpler use cases** - Not every graph workload needs clustering, online backups, or advanced security. A single-instance CE deployment is the right fit for many applications.

3. **Development and testing** - Teams building applications against Neo4j often want a quick, repeatable way to spin up a CE instance on AWS for development or CI/CD pipelines without licensing concerns.

4. **Learning and education** - Students, trainers, and self-learners benefit from a one-click deployment that gets them a working Neo4j instance on AWS.

5. **Gateway to Enterprise** - Many organizations start with CE and upgrade to EE as their needs grow. Providing a CE template creates a natural on-ramp.

6. **No Marketplace dependency** - The EE template relies on a Marketplace AMI. The CE template can use a standard Amazon Linux AMI, making it self-contained and independent of Marketplace listing updates.

---

## CE vs EE: Key Differences

The table below summarizes what is available in each edition and how this affects the CloudFormation template design.

### Database Features

| Feature | Community Edition | Enterprise Edition |
|---|---|---|
| Graph engine & ACID transactions | Yes | Yes |
| Cypher query language | Yes | Yes |
| Bolt / HTTP / HTTPS connectors | Yes | Yes |
| Multiple databases | No (system + 1 default only) | Yes |
| Composite databases | No | Yes |
| Clustering / high availability | No (single instance only) | Yes (autonomous clustering) |
| Online backup (while DB runs) | No (requires shutdown) | Yes |
| Change Data Capture (CDC) | No | Yes |
| Sharded property databases | No | Yes |

### Security

| Feature | Community Edition | Enterprise Edition |
|---|---|---|
| Password authentication | Yes | Yes |
| Role-based access control (RBAC) | No | Yes |
| Sub-graph access control | No | Yes |
| LDAP / Active Directory | No | Yes |
| Kerberos authentication | No | Yes |
| Security audit logging | No | Yes |

### Performance & Runtime

| Feature | Community Edition | Enterprise Edition |
|---|---|---|
| Slotted Cypher runtime | Yes | Yes |
| Pipelined Cypher runtime | No | Yes |
| Parallel Cypher runtime | No | Yes |
| Store format: Standard (deprecated) | Yes | Yes |
| Store format: Aligned (up to 34B nodes) | Yes | Yes |
| Store format: High Limit (up to 1 trillion nodes) | No | Yes |
| Store format: Block (optimized) | No | Yes |

### Operations

| Feature | Community Edition | Enterprise Edition |
|---|---|---|
| Neo4j Operations Manager (NOM) | No | Yes |
| Prometheus metrics | Yes | Yes |
| JMX metrics | Yes | Yes |
| Memory recommendation tool | Yes | Yes |
| APOC library | Yes | Yes |
| Graph Data Science (GDS) | Limited (single-threaded) | Full (multi-threaded) |
| Bloom visualization | No (requires license) | Yes |

### Licensing

| Aspect | Community Edition | Enterprise Edition |
|---|---|---|
| License | GPLv3 (open source) | Commercial (Neo4j License Agreement) |
| Cost | Free | Paid |
| AWS Marketplace AMI | Not available | Available |
| License acceptance during install | Not required | Required (`NEO4J_ACCEPT_LICENSE_AGREEMENT=yes`) |

---

## What Changes From the Existing EE Template

The CE template is fundamentally simpler than the EE template because it removes everything related to clustering, Marketplace integration, and Enterprise-only features. Here is a detailed breakdown of what changes, what stays, and what is new.

### Removed Entirely

| EE Component | Reason for Removal |
|---|---|
| **NumberOfServers parameter** | CE only supports a single instance. No cluster sizing needed. |
| **CreateCluster condition** | No clustering in CE. |
| **Subnet2, Subnet3** | Only one subnet needed for a single instance. |
| **Subnet2/3 RouteTableAssociations** | Follow from subnet removal. |
| **Internal Security Group** | Cluster communication ports (5000, 6000, 7000, 7688, 2003, 2004, 3637, 5005) are not needed. Port 5000 is also deprecated as of Neo4j 2025.01. |
| **Cluster discovery logic in UserData** | The entire block that queries the Auto Scaling Group via AWS APIs to discover cluster members is removed. CE has no cluster. |
| **Cluster configuration in neo4j.conf** | All `server.cluster.*`, `initial.dbms.default_primaries_count`, `dbms.cluster.*` settings are removed. |
| **Marketplace AMI parameter** | CE is not in the Marketplace. Use a standard Amazon Linux 2023 AMI instead. |
| **License acceptance** | `NEO4J_ACCEPT_LICENSE_AGREEMENT=yes` is not needed for CE. |
| **Bloom and GDS extension config** | Bloom requires a license. GDS Enterprise features are not available. Remove the `server.unmanaged_extension_classes` line for Bloom. |
| **`dbms.security.procedures.unrestricted=gds.*,bloom.*`** | These procedures are not available or meaningful in CE. Keep only `apoc.*` if APOC is installed. |
| **`dbms.routing.default_router=SERVER`** | Server-side routing is an EE clustering feature. |

### Simplified

| EE Component | CE Simplification |
|---|---|
| **Auto Scaling Group** | Fixed at MinSize=MaxSize=DesiredCapacity=1. Still useful for automatic instance recovery if the instance becomes unhealthy. Could alternatively be replaced with a standalone EC2 instance resource, but keeping the ASG provides self-healing. |
| **Network Load Balancer** | Optional for a single instance. Could be replaced with an Elastic IP for simplicity. However, keeping the NLB provides a stable DNS endpoint and makes the architecture consistent with the EE template. Decision point discussed in [Open Questions](#open-questions). |
| **IAM Role** | Permissions for `autoscaling:DescribeAutoScalingInstances` and `autoscaling:CreateOrUpdateTags` can be removed since there is no cluster discovery. If we remove the ASG entirely, the IAM role can be further reduced. |
| **UserData script** | Significantly shorter. Only needs: install Neo4j CE, configure network settings, configure memory, set password, start service. Roughly 40-50 lines instead of 111. |
| **Instance types** | Can keep the same list, but the default could be smaller (e.g., `r8i.large` or even `t3.medium`) since CE is typically used for lighter workloads. |
| **Disk size** | Can lower the minimum from 100 GB to something smaller (e.g., 30 GB) for development use cases. |

### Kept As-Is

| Component | Notes |
|---|---|
| **VPC** | Same 10.0.0.0/16 CIDR. |
| **Subnet1** | Single subnet in one AZ. |
| **Route Table + Route + IGW** | Same internet access pattern. |
| **External Security Group** | Same ports 7474 and 7687 open. Consider adding 7473 (HTTPS) if TLS is configured. |
| **EBS volume config** | Same GP3 encrypted volume. |
| **Password parameter** | Same approach for setting the admin password. |
| **Outputs** | Same BrowserURL, URI, and Username outputs. |

### New Additions for CE

| Addition | Rationale |
|---|---|
| **AMI lookup via SSM** | Use the AWS-managed Amazon Linux 2023 AMI via SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` instead of a Marketplace AMI. |
| **Java 21 installation** | The Marketplace AMI has Java pre-installed. With a stock Amazon Linux AMI, we must install Java 21 (required by Neo4j 2025.x) as part of provisioning. |
| **Neo4j version parameter** | Since we install from the Yum repository rather than a baked AMI, expose the Neo4j version as a parameter so users can pin to a specific release. |
| **APOC installation** | Optionally install the APOC plugin, which is the most commonly used Neo4j extension and is available for CE. |

---

## Proposed CE Template Design

### Parameters

```yaml
Parameters:
  Neo4jVersion:
    Description: >
      Neo4j Community Edition version to install.
      Use "latest" for the most recent stable release,
      or specify a version like "2025.12.0".
    Type: String
    Default: latest

  Password:
    Description: >
      Password for the neo4j admin user. Minimum 8 characters.
    Type: String
    MinLength: 8
    NoEcho: true

  InstanceType:
    Description: EC2 instance type
    Type: String
    Default: t3.medium
    AllowedValues:
      - t3.medium
      - t3.large
      - t3.xlarge
      - r8i.large
      - r8i.xlarge
      - r8i.2xlarge
      - r8i.4xlarge
      - r8i.8xlarge

  DiskSize:
    Description: Size in GB of the EBS volume
    Type: Number
    Default: 30
    MinValue: 10

  InstallAPOC:
    Description: Whether to install the APOC plugin
    Type: String
    Default: "yes"
    AllowedValues:
      - "yes"
      - "no"
```

### Resources (approximately 15, down from 26 in EE)

1. **VPC** - Same as EE.
2. **Subnet1** - Single subnet in one AZ.
3. **RouteTable** - Same as EE.
4. **Route** - Same as EE.
5. **SubnetRouteTableAssociation** - For Subnet1 only.
6. **InternetGateway** - Same as EE.
7. **InternetGatewayAttachment** - Same as EE.
8. **NetworkLoadBalancer** - Single-subnet NLB (or Elastic IP — see open questions).
9. **HTTPListener** - Port 7474.
10. **BoltListener** - Port 7687.
11. **HTTPTargetGroup** - Health check on 7474.
12. **BoltTargetGroup** - Health check on 7687.
13. **SecurityGroup** - Ports 7474 and 7687 inbound. No internal cluster ports.
14. **LaunchTemplate** - Amazon Linux 2023 AMI, GP3 EBS, UserData script.
15. **AutoScalingGroup** - Fixed at 1 instance.

### UserData Provisioning Script (Pseudocode)

```bash
#!/bin/bash
set -euo pipefail

# --- Install Java 21 ---
dnf install -y java-21-amazon-corretto-headless

# --- Install Neo4j Community Edition ---
rpm --import https://debian.neo4j.com/neotechnology.gpg.key
cat > /etc/yum.repos.d/neo4j.repo <<REPO
[neo4j]
name=Neo4j RPM Repository
baseurl=https://yum.neo4j.com/stable/latest
enabled=1
gpgcheck=1
REPO

if [ "${neo4jVersion}" == "latest" ]; then
  dnf install -y neo4j
else
  dnf install -y "neo4j-${neo4jVersion}"
fi

systemctl enable neo4j

# --- Install APOC (optional) ---
if [ "${installAPOC}" == "yes" ]; then
  # APOC is bundled as a plugin in the Neo4j distribution
  # Move it from labs to plugins directory
  cp /var/lib/neo4j/labs/apoc-*-core.jar /var/lib/neo4j/plugins/ 2>/dev/null || true
  echo "dbms.security.procedures.allowlist=apoc.*" >> /etc/neo4j/neo4j.conf
fi

# --- Configure network ---
sed -i 's/#server.default_listen_address=0.0.0.0/server.default_listen_address=0.0.0.0/g' /etc/neo4j/neo4j.conf
sed -i "s/#server.default_advertised_address=localhost/server.default_advertised_address=${loadBalancerDNSName}/g" /etc/neo4j/neo4j.conf
sed -i 's/#server.bolt.listen_address=:7687/server.bolt.listen_address=0.0.0.0:7687/g' /etc/neo4j/neo4j.conf
sed -i "s/#server.bolt.advertised_address=:7687/server.bolt.advertised_address=${loadBalancerDNSName}:7687/g" /etc/neo4j/neo4j.conf
sed -i 's/#server.http.listen_address=:7474/server.http.listen_address=0.0.0.0:7474/g' /etc/neo4j/neo4j.conf
sed -i "s/#server.http.advertised_address=:7474/server.http.advertised_address=${loadBalancerDNSName}:7474/g" /etc/neo4j/neo4j.conf

# --- Configure memory ---
neo4j-admin server memory-recommendation >> /etc/neo4j/neo4j.conf

# --- Enable metrics ---
echo "server.metrics.enabled=true" >> /etc/neo4j/neo4j.conf
echo "server.metrics.jmx.enabled=true" >> /etc/neo4j/neo4j.conf
echo "server.metrics.prefix=neo4j" >> /etc/neo4j/neo4j.conf
echo "server.metrics.filter=*" >> /etc/neo4j/neo4j.conf
echo "server.metrics.csv.interval=5s" >> /etc/neo4j/neo4j.conf

# --- Cypher IP blocklist ---
echo "internal.dbms.cypher_ip_blocklist=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.169.0/24,fc00::/7,fe80::/10,ff00::/8" >> /etc/neo4j/neo4j.conf

# --- Start Neo4j and set password ---
systemctl start neo4j
neo4j-admin dbms set-initial-password "${password}"
```

### Outputs

```yaml
Outputs:
  Neo4jBrowserURL:
    Description: URL for Neo4j Browser
    Value: !Sub "http://${NLB.DNSName}:7474"
  Neo4jURI:
    Description: Neo4j Bolt connection URI
    Value: !Sub "neo4j://${NLB.DNSName}:7687"
  Username:
    Description: The username is neo4j.
    Value: neo4j
  Edition:
    Description: Neo4j edition deployed
    Value: Community Edition (GPLv3)
```

---

## Best Practices From the Neo4j Operations Manual

The following best practices from the Neo4j Operations Manual (2025.x) apply to the CE template design. These are sourced from the official documentation at https://neo4j.com/docs/operations-manual/current/.

### Memory Configuration

The Operations Manual states that you should always explicitly define page cache and heap size rather than relying on heuristics. The `neo4j-admin server memory-recommendation` tool provides good starting values, but operators should review and tune them.

**Rules of thumb from the manual:**

- Leave 2-4 GB for the operating system.
- Set heap initial and max sizes to the same value to avoid GC pauses during heap expansion.
- Set page cache to: store size + expected growth + 10%.
- On a dedicated server, give remaining memory after OS and heap to the page cache.

The CE template uses the memory recommendation tool as a starting point, which is the correct approach for an automated deployment. Users who need to tune further can SSH into the instance and modify `/etc/neo4j/neo4j.conf`.

### Network Configuration

The manual recommends binding to `0.0.0.0` for listen addresses when the server needs to accept connections from external clients, and setting the advertised address to the hostname or DNS name that clients will use to connect. The CE template does this correctly by using the NLB DNS name as the advertised address.

For production deployments, the manual recommends enabling HTTPS (port 7473) and disabling HTTP (port 7474) once TLS certificates are configured. The CE template keeps HTTP enabled by default for ease of getting started, but this should be documented as a post-deployment hardening step.

### Ports

Per the Operations Manual, the ports relevant to a CE deployment are:

| Port | Protocol | Purpose |
|---|---|---|
| 7474 | HTTP | Neo4j Browser and HTTP API |
| 7473 | HTTPS | Neo4j Browser and HTTP API (encrypted) |
| 7687 | Bolt | Driver connections (Cypher Shell, SDKs) |

Cluster-only ports (6000, 7000, 7688) and the online backup port (6362) are not applicable to CE.

### Security

The manual emphasizes that authentication must always be enabled (it is by default). For CE, the security model is limited to password authentication for the `neo4j` user. There is no RBAC, no sub-graph access control, and no LDAP integration. This means network-level security (security groups, NACLs, VPN) is especially important for CE deployments since the database itself cannot enforce fine-grained access control.

The Cypher IP blocklist (`internal.dbms.cypher_ip_blocklist`) should be configured to prevent Cypher queries from making network calls to internal AWS infrastructure, which the template does.

### Backup

CE does not support online backup. The only way to back up a CE instance is to:

1. Stop the Neo4j service.
2. Copy the data directory (default: `/var/lib/neo4j/data`).
3. Restart Neo4j.

Alternatively, use EBS snapshots, which can be taken while the instance is running. While not application-consistent, EBS snapshots combined with Neo4j's recovery-on-startup mechanism provide a practical backup approach for CE. This should be documented in the template's description and outputs.

### JVM Configuration

The manual recommends the G1GC garbage collector (default in Neo4j 2025.x) and the `-XX:+AlwaysPreTouch` flag to pre-commit memory at startup. These are set by default in the Neo4j distribution and do not need explicit configuration in the template.

Neo4j 2025.x requires Java 21. Starting with version 2025.10, Java 25 is also supported. The template should install Amazon Corretto 21 (Amazon's build of OpenJDK), which is the recommended JVM on Amazon Linux.

### Configuration Validation

Starting with recent Neo4j versions, the `neo4j.conf` file has strict validation enabled by default. If the config file contains typos, incorrect values, or duplicate settings (other than `server.jvm.additional`), Neo4j will refuse to start. This means the provisioning script must be carefully tested to ensure it produces a valid configuration file.

---

## Implementation Plan

### Step 1: Create the CloudFormation Template

Create `neo4j-ce/neo4j.template.yaml` with the resources described in the [Proposed CE Template Design](#proposed-ce-template-design) section. Start by copying the EE template and removing/simplifying the components listed in [What Changes From the Existing EE Template](#what-changes-from-the-existing-ee-template).

Key tasks:
- Replace Marketplace AMI with Amazon Linux 2023 AMI via SSM parameter.
- Remove all clustering resources (Subnet2, Subnet3, Internal Security Group, conditions).
- Remove cluster configuration from UserData.
- Add Java 21 installation step.
- Change package from `neo4j-enterprise` to `neo4j`.
- Remove license acceptance.
- Add Neo4j version parameter.
- Add APOC installation option.
- Simplify instance type defaults and disk size minimum.

### Step 2: Update the Deploy Script

Update `neo4j-ce/deploy.sh` to pass the new parameters (Neo4jVersion, InstallAPOC) and remove any EE-specific parameters.

### Step 3: Test the Template

- Deploy the stack in us-east-1 and verify Neo4j starts successfully.
- Verify Neo4j Browser is accessible via the NLB DNS name on port 7474.
- Verify Bolt connections work on port 7687.
- Verify APOC procedures are available when InstallAPOC=yes.
- Verify memory settings are applied correctly.
- Test with different instance types (t3.medium, r8i.large).
- Test stack deletion cleans up all resources.

### Step 4: Documentation

- Update the root README.md to mention the CE template and link to it.
- Add a README.md in `neo4j-ce/` with CE-specific deployment instructions.
- Document the backup strategy (EBS snapshots) since online backup is not available.
- Document post-deployment hardening steps (restrict security group CIDRs, enable HTTPS).

---

## Open Questions

### 1. NLB vs Elastic IP for Single Instance?

The EE template uses a Network Load Balancer, which makes sense for distributing traffic across cluster members. For a single CE instance, the NLB adds cost (~$16/month) without load-balancing benefit.

**Option A: Keep the NLB.** Provides a stable DNS endpoint. If the ASG replaces the instance, the NLB automatically routes to the new instance. Consistent architecture with the EE template.

**Option B: Use an Elastic IP.** Lower cost ($0 when attached to a running instance). Requires a custom script or Lambda to reassociate the EIP if the instance is replaced. Simpler but less resilient.

**Recommendation:** Keep the NLB for consistency and resilience. The cost is minor relative to the EC2 instance cost.

### 2. ASG vs Standalone EC2 Instance?

The ASG with MinSize=MaxSize=1 provides automatic instance recovery. If the instance fails a health check, the ASG terminates it and launches a new one. However, the new instance starts with a fresh EBS volume, meaning data is lost unless external backups exist.

**Option A: Keep the ASG.** Provides self-healing. Pair with a note that users should set up EBS snapshots for data durability.

**Option B: Use a standalone EC2 instance.** Simpler template. Users manage recovery manually.

**Recommendation:** Keep the ASG but add documentation about data durability. The self-healing behavior is valuable even if it means starting fresh.

### 3. Should we pre-bake a CE AMI?

The EE template uses a Marketplace AMI with Neo4j pre-installed. For CE, we could either install from the Yum repository at boot time (slower but simpler) or build a custom AMI with Neo4j pre-installed (faster boot but requires AMI maintenance).

**Option A: Install at boot.** No AMI maintenance. Always gets the latest version from the repository. Adds 2-3 minutes to startup time.

**Option B: Pre-bake an AMI.** Faster startup. Requires a build process and AMI updates for each Neo4j release.

**Recommendation:** Start with Option A (install at boot). The simplicity outweighs the startup time difference. A pre-baked AMI can be added later if startup time becomes a concern.

### 4. Default Instance Type

The EE template defaults to `r8i.xlarge` (8 vCPU, 64 GB RAM). For CE, which targets smaller workloads, a smaller default may be more appropriate.

**Recommendation:** Default to `t3.medium` (2 vCPU, 4 GB RAM) for cost efficiency. Users deploying production workloads can select a larger instance. Document that memory-optimized instances (r8i family) are recommended for databases larger than a few GB.

---

## References

### Neo4j Documentation
- [Neo4j Operations Manual](https://neo4j.com/docs/operations-manual/current/) — Primary source for deployment and configuration guidance.
- [Introduction (Edition Comparison)](https://neo4j.com/docs/operations-manual/current/introduction/) — Feature matrix comparing CE and EE.
- [Neo4j on AWS](https://neo4j.com/docs/operations-manual/current/cloud-deployments/neo4j-aws/) — AWS-specific deployment guidance.
- [Configuration Settings](https://neo4j.com/docs/operations-manual/current/configuration/configuration-settings/) — Complete configuration reference.
- [Memory Configuration](https://neo4j.com/docs/operations-manual/current/performance/memory-configuration/) — Memory tuning guidelines.
- [Ports](https://neo4j.com/docs/operations-manual/current/configuration/ports/) — Port reference for all editions.
- [SSL Framework](https://neo4j.com/docs/operations-manual/current/security/ssl-framework/) — TLS/SSL configuration.
- [Changes and Deprecations in 2025.x](https://neo4j.com/docs/operations-manual/current/changes-deprecations-removals/) — Breaking changes in recent versions.

### AWS Documentation
- [Amazon Linux 2023 AMI](https://docs.aws.amazon.com/linux/al2023/ug/what-is-amazon-linux.html)
- [AWS CloudFormation Best Practices](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/best-practices.html)

### Community Resources
- [Neo4j Community vs Enterprise Feature Discussion](https://community.neo4j.com/t/feature-matrix-comparing-community-and-enterprise-versions/62252)
- [Production-Ready Neo4j Guide](https://medium.com/@satanialish/the-production-ready-neo4j-guide-performance-tuning-and-best-practices-15b78a5fe229)
- [Choose the Right Neo4j Offering](https://neo4j.com/blog/news/neo4j-offering/)
