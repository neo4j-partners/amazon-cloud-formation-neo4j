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
   "template.json"],
  capture_output=True, text=True)
logging.debug(cmd.stdout)

#Command to feed dummy output for debugging purposes
# cmd = subprocess.run(["cat", "output.out"], stdout=subprocess.PIPE, text=True)

#Fail script on Packer error
if cmd.returncode != 0 :
  sys.exit("Packer build failed!")

#Parse Packer output to get generated AMI IDs and thei respective regions
raw_exec_output = cmd.stdout.split("AMIs were created:")
logging.debug(f'{raw_exec_output=}')
parsed_data = raw_exec_output[1].split("\n")
logging.debug(f'{parsed_data=}')

#Format Packer output to be put in CFT template
output="Mappings:\n  Neo4j:\n"
for line in parsed_data:
  if "ami-" in line:
    logging.debug(f'{line=}')
    region, ami_id = line.split(": ")
    output += f"    {region}:\n      BYOL: {ami_id}\n"
logging.debug(f'Total output:{ output}')

#Update CFT Mappings with fresh AMI IDs and regions
with open("../neo4j-enterprise/neo4j.template.yaml", "r") as file:
  template = file.read()
  ami_index = template.find("Mappings:\n  Neo4j:\n")
  updated_template = f'{template[:ami_index]}\n{output}'

with open("../neo4j-enterprise/neo4j.template.yaml", "w") as file:
  file.write(updated_template)

