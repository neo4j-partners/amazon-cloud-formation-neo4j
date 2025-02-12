#!/usr/bin/env python

#INTERNAL USE ONLY!

import subprocess
import argparse
import logging
import sys

logging.basicConfig(level=logging.DEBUG)
logging.debug('Setting up logger')

parser = argparse.ArgumentParser()
parser.add_argument('--aws-account', default='385155106615', help='AWS account to do the work in.')
parser.add_argument('--aws-region', default='us-east-1', help='AWS region to do the work in.')
parser.add_argument('--destination-regions', default='us-east-1', help='A comma separate list of regions.')
args = parser.parse_args()

logging.info('Running packer build and collecting output')

#Running Packer build command
cmd = subprocess.run(
  ["packer", "build",
   "-var", f"aws_account={args.aws_account}",
   "-var", f"aws_region={args.aws_region}",
   "-var", f"destination_regions={args.destination_regions}",
   "arm-template.json"],
  capture_output=True, text=True)

# Print both stdout and stderr if there's an error
if cmd.returncode != 0:
    print("Packer stdout:")
    print(cmd.stdout)
    print("\nPacker stderr:")
    print(cmd.stderr)
    sys.exit("Packer build failed!")

logging.debug(cmd.stdout)

#Parse Packer output to get generated AMI IDs and their respective regions
raw_exec_output = cmd.stdout.split("AMIs were created:")
logging.debug(f'{raw_exec_output=}')
parsed_data = raw_exec_output[1].split("\n")
logging.debug(f'{parsed_data=}')

#Format Packer output to be put in CFT template
output="Mappings:\n  Neo4j:\n"
for line in parsed_data:
  if "ami-" in line and "-arm64" in line:  # Only process ARM64 AMIs
    logging.debug(f'{line=}')
    region, ami_id = line.split(": ")
    output += f"    {region}:\n      BYOL: {ami_id}\n"  # Keep the original BYOL format

logging.debug(f'Total output:{output}')

#Update CFT Mappings with fresh AMI IDs and regions
template_file = "../neo4j-enterprise/neo4j.template.yaml"
try:
    with open(template_file, "r") as file:
        template = file.read()
        ami_index = template.find("Mappings:\n  Neo4j:\n")
        updated_template = f'{template[:ami_index]}\n{output}'

    with open(template_file, "w") as file:
        file.write(updated_template)
    logging.info(f'Successfully updated {template_file} with ARM64 AMI IDs')
except FileNotFoundError:
    logging.error(f'Template file {template_file} not found')
    sys.exit(1)