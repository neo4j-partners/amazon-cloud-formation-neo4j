#!/bin/bash
# This just packages the solution templates into the format the marketplace
# expects to make an easy manual submission package.
zip -9r pkg.zip * --exclude \*.jinja --exclude \*.zip --exclude package.sh
