set_neo4j_conf() {
  local conf=/etc/neo4j/neo4j.conf
  sed -i "s|^#\?$1=.*|$1=$2|" "$conf"
  if ! grep -q "^$1=" "$conf"; then
    echo "$1=$2" >> "$conf"
  fi
}
