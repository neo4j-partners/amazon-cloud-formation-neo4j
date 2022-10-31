#!/usr/bin/env python

#INTERNAL USE ONLY!

import subprocess
import logging
import sys
import re

logging.basicConfig(level=logging.INFO)
logging.debug('Setting up logger')

#Setting up cli arguments check. Argument should be Neo4j version
if len(sys.argv[1]) > 1:
  logging.debug('Got argument from commandline '+sys.argv[1])
  neo4j_version = sys.argv[1]
else:
  sys.exit("Neo4j version parameter not specified!")

logging.info('Running packer build and collecing output')

#Running Packer build command
version = "neo4j_version=%s" % neo4j_version
logging.debug(version)
cmd = subprocess.run(["packer", "build", "-var", version, "template.json" ], capture_output=True, text=True)
logging.debug(cmd.stdout)
#Command to feed dummy output for debugging purposes
# cmd = subprocess.run(["cat", "output.out"], stdout=subprocess.PIPE, text=True)

#Fail script on Packer error
if cmd.returncode != 0 :
  sys.exit("Packer build failed!")

#Parse Packer output to get generated AMI IDs and thei respective regions
raw_exec_output = cmd.stdout.split("AMIs were created:")
logging.debug('Raw exec:'+str(raw_exec_output))
parsed_data = raw_exec_output[1].split("\n")
logging.debug('Parsed data:'+str(parsed_data))
logging.debug(parsed_data[0])

#Format Packer output to be put in CFT template
output="Mappings:\n  Neo4j:\n"
for line in parsed_data:
  if "ami-" in line:
    logging.debug(line)
    elm = line.split(": ")
    output+="    "+elm[0]+":\n      BYOL: "+elm[1]+"\n"
logging.debug('Total output:'+output)

#Bump Neo4j version and write it to CFT template
default_version= "Default: '%s'" % neo4j_version
default_template = open('../neo4j.template.yaml', 'r')
content = default_template.read()
template = re.sub("Default:\s\'\d{1,2}\.\d{1,2}\.\d{1,2}\'", default_version, content, flags = re.M)
default_template.close()
handled_template = open('../neo4j.template.yaml', 'w')
handled_template.write(template)
handled_template.close()

#Update CFT Mappings with fresh AMI IDs and regions
updated_template = open("../neo4j.template.yaml", "r")
final_template = updated_template.read()
final_template = template.split("\nMappings:")
updated_template.close()
updated_template = open("../neo4j.template.yaml", "w")
updated_template.write(final_template[0]+"\n"+output)
updated_template.close()

#Bump Neo4j version in deploy.sh
graph_database_version = f'GraphDatabaseVersion={neo4j_version}'
deploy_script_file = open('../deploy.sh', 'r')
script = deploy_script_file.read()
script_updated = re.sub("GraphDatabaseVersion=\d{1,2}\.\d{1,2}\.\d{1,2}", graph_database_version, script, flags = re.M)
deploy_script_file.close()
deploy_script_file = open('../deploy.sh', 'w')
deploy_script_file.write(script_updated)
deploy_script_file.close()