from jinja2 import Environment, Template, BaseLoader, TemplateNotFound
from os.path import join, exists, getmtime 
import json
import re

# Custom filters to make generating templates less painful.

def appendStack(input):
      return """{
            "Fn::Join": [
                  "-",
                  ["%s", { "Ref": "AWS::StackName" }]
            ]
      }""" % input

def roundRobinAZ(someIndex, totalAZs=3):
      """Evenly distribute resources across 3 AZs for avaialability"""
      azIdx = someIndex % totalAZs
      return """{
            "Fn::Select": [ %d, { "Fn::GetAZs" : { "Ref": "AWS::Region" } }]
      }""" % azIdx

def jsonizeFile(filename):
      """
      AWS expects us to encode shell scripts as JSON, because JSON all the things.
      lolsob. :(
      So here, we're trying to turn a shell script like this:
      
      #!/bin/bash
      echo "Foo"

      into:

      {
            "Fn::Join": [
                  "",
                  [
                        "#/bin/bash\n",
                        "echo \"Foo\"\n"
                  ]
            ]
      }

      Much JSON.  Very ouch.  Wow.
      """
      with open(filename, "r") as file:
            content = file.readlines()
            preamble = """{ "Fn::Join": [
                  "",
                  ["""
            closer = """]
             ]
            }"""

            allLines = ",\n".join(map(lambda i: '"%s"' % re.sub(r"\n", "\\\\n", i), content))
            return preamble + allLines + closer

class FileLoader(BaseLoader):
   def __init__(self, path):
      self.path = path
   def get_source(self, environment, template):
      path = join(self.path, template)
      if not exists(path):
         raise TemplateNotFound(template)
      mtime = getmtime(path)
      with open(path, 'r') as f:
         source = f.read()
      # print("TMPL SOURCE %s" % source)
      return source, path, lambda: mtime == getmtime(path)

env = Environment(loader=FileLoader('./'))

env.filters['appendStack'] = appendStack
env.globals['jsonizeFile'] = jsonizeFile
env.globals['roundRobinAZ'] = roundRobinAZ

template = env.get_template('deploy.jinja')
tmpl_content = template.render()

with open('generated.json', 'w') as f:
      f.write(tmpl_content)
      f.close()

# Re-parse and export pretty-printed, since template jinja mixture gets ugly
# and hard to read fast.
parsed = json.loads(tmpl_content.strip())
print(json.dumps(parsed, indent=2, sort_keys=False))

