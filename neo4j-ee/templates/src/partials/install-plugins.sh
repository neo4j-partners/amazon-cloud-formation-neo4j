install_apoc() {
  echo "Installing APOC plugin..."
  cp /var/lib/neo4j/products/apoc-*-core.jar /var/lib/neo4j/plugins/ 2>/dev/null || true
}
install_plugin() {
  local label="$1" pattern="$2"
  local jar
  jar=$(ls /var/lib/neo4j/products/${pattern} 2>/dev/null | head -1 || true)
  if [ -z "$jar" ]; then
    fail "${label} JAR not found in /var/lib/neo4j/products/; rebuild AMI or disable Install${label}."
  fi
  echo "Installing ${label} plugin from $jar..."
  cp "$jar" /var/lib/neo4j/plugins/
  chown neo4j:neo4j /var/lib/neo4j/plugins/$(basename "$jar")
}
