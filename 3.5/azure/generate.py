from jinja2 import Environment, Template, BaseLoader, TemplateNotFound
from os.path import join, exists, getmtime 
import json
import argparse
import sys
import re

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

parser = argparse.ArgumentParser(description='Generate ARM JSON from template')
parser.add_argument('--template', type=str, help='template file')
args = parser.parse_args()

template = env.get_template(args.template)
tmpl_content = template.render()

if args.template is None:
      print("Template argument is required!")
      sys.exit(1)

with open('generated.json', 'w') as f:
      f.write(tmpl_content)
      f.close()

# Re-parse and export pretty-printed, since template jinja mixture gets ugly
# and hard to read fast.
try:
      parsed = json.loads(tmpl_content.strip())
except Exception as e:
      raise Exception("Generated JSON for %s is invalid: %s" % (args.template, str(e)), e)

# print(json.dumps(parsed))
# Prettyprint
print(json.dumps(parsed, indent=2, sort_keys=False))

