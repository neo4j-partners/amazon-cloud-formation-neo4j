#!/bin/bash

echo "Jinja Expansion"
# Expand all jinja templates into regular JSON
for file in arm/*.json.jinja arm/nestedtemplates/*.json.jinja ; do
    # Bash magic that removes jinja extension.  foo.json.jinja -> foo.json
    jsonFile=${file%.jinja}
    echo $jsonFile
    python3 generate.py --template "$file" > "$jsonFile" ;
    if [ $? -ne 0 ] ; then
        echo "Template generation of $file failed; aborting"
        echo "Check your template syntax and try again"
        echo "Local file 'generated.json' contains last output; check this to correlate"
        echo "syntax errors with line numbers from previous exception"
        exit 1
    fi
done