# Marketplace

Internal instructions for Neo4j employees managing the EE Marketplace listing.

## Scripts

| Script | Purpose |
|---|---|
| `create-ami.sh` | Builds the base AMI: resolves the latest AL2023 AMI, patches OS, hardens SSH, creates AMI, writes ID to `ami-id.txt` |
| `test-ami.sh` | Verifies the AMI via SSM Run Command (no SSH required): checks SSH hardening and OS identity |

## Updating the AMI

Run from the `neo4j-ee/` directory against the `marketplace` AWS profile:

```bash
AWS_PROFILE=marketplace ./marketplace/create-ami.sh
```

The script resolves the latest Amazon Linux 2023 AMI from SSM, patches it with
`dnf update -y`, hardens SSH, creates the AMI in `us-east-1`, enforces IMDSv2,
and writes the new AMI ID to `marketplace/ami-id.txt`.

Then test it:

```bash
AWS_PROFILE=marketplace ./marketplace/test-ami.sh
```

The test script launches a temporary instance from the AMI, runs verification
checks over SSM, reports pass/fail, and terminates the instance on exit.

## Submitting a New Version to Marketplace

After the AMI passes testing:

1. Upload the three EE templates to the Marketplace S3 bucket in `us-east-1`:

```
s3://marketplace-neo4j/neo4j-private.template.yaml
s3://marketplace-neo4j/neo4j-public.template.yaml
s3://marketplace-neo4j/neo4j-private-existing-vpc.template.yaml
```

2. Open the [AWS Marketplace Seller Portal](https://aws.amazon.com/marketplace/management/) and navigate to:
   **Products > Server > Request changes > Update versions > Add version**

3. Fill in the version form:
   - **AMI ID:** the ID from `marketplace/ami-id.txt`
   - **IAM access role ARN:** `arn:aws:iam::385155106615:role/aws_marketplace_ami_ingestion`
   - **CloudFormation template links:** the three S3 URLs from step 1
   - **Architecture diagram:** `https://marketplace-neo4j.s3.us-east-1.amazonaws.com/arch-ee.png`

4. Submit for scanning. AWS will validate the AMI against Marketplace security
   requirements. Once approved, publish the new version.

The `ImageId` parameter in the templates uses `AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>`.
AWS Marketplace injects the correct SSM parameter path at subscription time.
There is no AMI ID to update in the templates themselves.
