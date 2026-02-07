# Marketplace

These are instructions to update the Neo4j Community Edition marketplace listing. Unless you are a Neo4j employee doing so, you should not need to do any of this.

## Updating the Listing

The listing is managed in the portal [here](https://aws.amazon.com/marketplace/management/products/server). You can update listing copy in that portal.

## Updating the AMI

The CE AMI uses a hybrid approach: Java 21 and Neo4j Community Edition are pre-installed in the image. This means the AMI must be rebuilt for each new Neo4j version release, as well as for OS and Java security patches.

### When to Rebuild

| Trigger | Action |
|---|---|
| New Neo4j CE version released | Rebuild AMI with new Neo4j version. Add as new Marketplace product version. |
| Critical CVE in OS or Java | Rebuild AMI with `dnf update -y`. Replace existing version. |
| Amazon Linux 2023 EOL (2028) | Migrate to successor base AMI. |

### Automated Build (Recommended)

The `create-ami.sh` script automates the entire AMI build — no SSH or console clicks required. It launches a temporary instance, runs the build via UserData, waits for it to stop, creates the AMI, tags it, and terminates the build instance.

Ensure your AWS CLI is configured with the `marketplace` profile (account `385155106615`). Export it once so all scripts pick it up:

```bash
export AWS_PROFILE=marketplace
```

The script verifies the account before proceeding and overrides the region to `us-east-1`:

```bash
./create-ami.sh 2026.01.3
```

The script writes the AMI ID to `ami-id.txt` for use by downstream scripts. Then test and scan:

1. **Automated test:** Run `test-ami.sh` to verify the AMI (see [Testing the AMI](#testing-the-ami) below).
2. **Marketplace scan:** Submit the AMI via "Test Add Version" in the portal to verify compliance.

### Testing the AMI

The `test-ami.sh` script automates AMI verification using SSM Run Command — no SSH key or port 22 required. It launches a temporary instance, runs checks over SSM, reports pass/fail, and terminates the instance.

```bash
# Uses ami-id.txt written by create-ami.sh
./test-ami.sh

# Or pass an AMI ID explicitly
./test-ami.sh ami-089ef8c9f4da68869
```

The script verifies:
- Neo4j is installed and the correct version
- Java 21 is installed
- SSH password authentication is disabled
- Root login is restricted
- Neo4j service is enabled
- neo4j.conf exists
- APOC jar is available

On first run, it creates a temporary IAM role (`neo4j-ce-ami-test-ssm-role`) with the `AmazonSSMManagedInstanceCore` policy. This role is reused on subsequent runs.

### Manual Build (Alternative)

If you prefer to build manually or need to debug the build process:

1. Start an EC2 instance with the latest Amazon Linux 2023 AMI (HVM, x86_64, EBS-backed) in us-east-1.
2. SSH in and run `build.sh`:
   ```bash
   sudo bash build.sh
   ```
3. In the EC2 console, select the stopped instance and choose **Actions > Image and templates > Create image**.
4. Tag the AMI with `Name`, `Neo4jVersion`, `Neo4jEdition`, and `Purpose` tags.
5. Test and scan as described above.

## Updating the CFT

With the AMI updated, you can update the CFT. That is done by adding a new version in the portal. You'll also need to update the `ImageId` parameter default in the CFT.

* **AMI ID** - Should be the AMI you made earlier.
* **IAM access role ARN** - `arn:aws:iam::385155106615:role/aws_marketplace_ami_ingestion`
* **CloudFormation template link** - The form requires that the template be in S3. Upload it to the CE S3 bucket.
* **Architecture diagram link** - Upload `arch.png` to the same S3 bucket.

## Creating a New Marketplace Listing (First Time Only)

If this is the first time publishing the CE product:

1. Go to the [Marketplace Management Portal](https://aws.amazon.com/marketplace/management/products/server).
2. Create a new product (separate from the EE listing).
3. Configure as a **free** product ($0 software charge).
4. Upload the CloudFormation template and architecture diagram.
5. Submit the AMI and template for Marketplace scanning and review.
6. Test in **Limited** visibility mode.
7. Request **Public** visibility once testing is complete.

The existing EE Marketplace listing satisfies the 90-day requirement for free/community editions to have a paid equivalent available.

## Portal

The marketplace management portal is [here](https://aws.amazon.com/marketplace/management/products/server).
