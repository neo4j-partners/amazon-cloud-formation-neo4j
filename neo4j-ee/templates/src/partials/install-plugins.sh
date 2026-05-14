install_apoc() {
  local jar
  jar=$(ls /var/lib/neo4j/labs/apoc-*-core.jar 2>/dev/null | head -1 || true)
  if [ -z "$jar" ]; then
    fail "APOC core JAR not found in /var/lib/neo4j/labs after installing neo4j-enterprise."
  fi
  echo "Installing APOC plugin..."
  cp "$jar" /var/lib/neo4j/plugins/
  chown neo4j:neo4j /var/lib/neo4j/plugins/$(basename "$jar")
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
