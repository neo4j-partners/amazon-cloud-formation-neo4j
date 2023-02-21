# Content
This directory contains tools to automate AWS Marketplace CFT generation.
If you are running this from your local machine you need to have `Python` and `Packer` installed.

The Python script first runs Packer which will generate a new AMI based on Amzn Linux2, will copy it across all the supported regions and as a result will give us some output with new AMI IDs and the regions where we can find them.
Then it will parse the Packer output and will update the CFT with the new Mappings. The script also updates the CFT with the new Neo4j version passed as an argument during runtime.

# Instructions
* RUN the script:
```
python parser.py <Neo4j-version>
```
* When finished it will update `neo4j.template.yaml` in marketplace repo.

* Test the new template and merge to main branch if it runs successfully.

* Continue the submitting process by updating Product Load Form.


