# Local K3S Deployment Checklist
These procedures cover manual local deployment of a lab environment, including
the Clickhouse and Keeper clusters, and monitoring components (Grafana and Prometheus).
Assumes that you already have Kafka available as a feeder - see KAFKA_SCRAPERS_LOCAL_DEPLOYMENT.md
Tested in k3s, but should work in other Kubernetes environments.


### 1. Prepare Certificates
This assumes you've already set up Kafka and have certs/keys available in the certs directory.
See KAFKA_SCRAPERS_LOCAL_DEPLOYMENT.md

### 2. Apply lables to Nodes (optional)
We can steer workloads to nodes using a combination of preferred scheduling and taints/tolerations.
For namespaces with multiple component types (clickhouse and kafka), the workload values define each component:
- adsb-clickhouse
- adsb-clickhouse-keeper
- adsb-monitoring

Example: To steer both Clickhouse and Keeper resources to the same node(s):
kubectl label nodes <node-name> adsb-clickhouse=true adsb-clickhouse-keeper=true
kubectl label nodes <node-name> adsb-keeper=true

Removing a label:
kubectl label nodes <node-name> adsb-clickhouse-

Check node labels:
kubectl get nodes --show-labels
kubectl get nodes -l adsb-clickhouse=true

## Deploying ClickHouse and Monitoring components
The Ansible automation assumes deployment in EKS.  If you instead want to deploy locally in k8s/k3s/etc:

### Prepare Manifests
- copy manifests/10-secrets-kafka-tls.yaml.example to 10-secrets-kafka-tls.yaml
- populate with the base64-encoded keypair values from step 1
- copy schema/users.sql.example to schema/users.sql
- update the passwords for the query and ingest users
- copy manifests/10-grafana-config.yaml.example to 10-grafana-config.yaml
- populate passwords for the query and ingest users
- copy manifests/30-clickhouse.yaml.example to 30-clickhouse-local.yaml (or similar)
- update the kafka broker lists, and the admin user password_sha256_hex
- apply labels to nodes

### Download Prometheus CRDs
From the adsb-ansible directory, run:
  scripts/prometheus-crds.sh

### Deploy ClickHouse Stack
```bash
# 1. Install Altinity Clickhouse Operator
#curl -s https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator-web-installer/clickhouse-operator-install.sh | bash
#kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-bundle.yaml

# 2. Create namespace
kubectl apply -f manifests/adsb-clickhouse/00-namespace.yaml

# 3. Create secrets (your customized file)
kubectl apply -f manifests/adsb-clickhouse/10-secrets-kafka-tls.yaml

# 4. Deploy Keeper
kubectl apply -f manifests/adsb-clickhouse/20-keeper.yaml
kubectl get pods -n adsb-clickhouse -w

# 5. Deploy Clickhouse
kubectl apply -f manifests/adsb-clickhouse/30-clickhouse-local.yaml
kubectl get pods -n adsb-clickhouse -w

# 6. Install DB schema and users
clickhouse-client --host <host> --user admin --password clickhouse123 --port 30900 --multiquery < schema/schema.sql
clickhouse-client --host <host> --user admin --password clickhouse123 --port 30900 --multiquery < schema/users.sql
```

### Deploy Monitoring Stack
```bash
# 1. Install Prometheus CRDs
./scripts/prometheus-crds.sh

# 2. Create namespace
kubectl apply -f manifests/adsb-monitoring/00-namespace.yaml

# 3. Install Prometheus Operator and wait for it to be ready
kubectl apply -f manifests/adsb-monitoring/10-prometheus-operator.yaml
kubectl wait --for=condition=available --timeout=300s deployment/prometheus-operator -n adsb-monitoring

# 4. Deploy Prometheus
kubectl apply -f manifests/adsb-monitoring/11-prometheus.yaml

# 5. Deploy service monitors
kubectl apply -f manifests/adsb-monitoring/12-servicemonitor-operator.yaml
kubectl apply -f manifests/adsb-monitoring/13-servicemonitor-clickhouse.yaml
kubectl apply -f manifests/adsb-monitoring/14-servicemonitor-keeper.yaml

# 5. Download and install Altinity dashboard configmap
./scripts/download-altinity-dashboard.sh
kubectl create configmap altinity-dashboards --from-file=./dashboards/altinity-clickhouse-operator-dashboard.json -n adsb-monitoring

# 6. Install ADS-B dashboard configmap
kubectl create configmap adsb-dashboards --from-file=./dashboards/adsb/ -n adsb-monitoring

# 7. Apply Grafana configs
kubectl apply -f manifests/adsb-monitoring/20-grafana-config.yaml

# 8. Deploy Grafana
kubectl apply -f manifests/adsb-monitoring/25-grafana.yaml
kubectl get pods -n adsb-monitoring -w
```