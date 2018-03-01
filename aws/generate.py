from jinja2 import Environment, Template, BaseLoader, TemplateNotFound
from os.path import join, exists, getmtime 

# Custom filters to make generating templates less painful.

def appendStack(input):
      return """{
            "Fn::Join": [
                  "-",
                  ["%s", { "Ref": "AWS::StackName" }]
            ]
      }""" % input

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

template = env.get_template('deploy.jinja')
print(template.render())
