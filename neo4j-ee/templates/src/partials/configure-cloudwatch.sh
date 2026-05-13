install_cloudwatch_agent() {
  echo "Configuring CloudWatch agent..."
  cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWCONFIG
{"logs":{"logs_collected":{"files":{"collect_list":[{"file_path":"/var/log/neo4j/security.log","log_group_name":"/neo4j/${stackName}/application","log_stream_name":"{instance_id}/security","retention_in_days":90},{"file_path":"/var/log/neo4j/debug.log","log_group_name":"/neo4j/${stackName}/application","log_stream_name":"{instance_id}/debug","retention_in_days":90},{"file_path":"/var/log/cloud-init-output.log","log_group_name":"/neo4j/${stackName}/application","log_stream_name":"{instance_id}/cloud-init-output","retention_in_days":90}]}}}}
CWCONFIG
  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
}
