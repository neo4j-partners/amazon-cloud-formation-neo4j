install_neo4j_from_yum() {
  echo "Installing Graph Database..."
  export NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
  yum -y install neo4j-enterprise
  systemctl enable neo4j
}
start_neo4j() {
  local initialPassword="$1"
  echo "Starting Neo4j..."
  service neo4j start
  if [[ "${IS_FIRST_BOOT}" == "true" ]]; then
    neo4j-admin dbms set-initial-password "${initialPassword}"
  fi
}
