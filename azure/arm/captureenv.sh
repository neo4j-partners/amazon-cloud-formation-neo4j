#!/bin/bash

echo "#!/bin/bash" > "$(dirname $0)/re-setup.sh"
compgen -v | while read VAR; do
    echo "if [ -z \"\$$VAR\" ]; then" >> "$(dirname $0)/re-setup.sh"
    declare -xp $VAR >> "$(dirname $0)/re-setup.sh"
    echo "fi" >> "$(dirname $0)/re-setup.sh"
done
echo 'source "$(dirname $0)/setup.sh"' >> "$(dirname $0)/re-setup.sh"
