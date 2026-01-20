# ADSB EKS Deployment Checklist
These procedures assume that a Kafka or Redpanda cluster is running and accessible, and that the required
keys were stored in the certs directory (review certs/README.md)

Copy the manifests/30-clickhouse-eks.yaml.template file to manifests/30-clickhouse-eks.yaml
Modify each <kafka_broker_list> stanza, replacing the placeholder URL(s) to the FQDN of your Kakfa brokers

