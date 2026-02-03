# Local K3S Deployment Checklist
These procedures cover manual local deployment of a lab environment, including
the Clickhouse and Keeper clusters, and monitoring components (Grafana and Prometheus).
Assumes that you already have Kafka available as a feeder - see KAFKA_SCRAPERS_LOCAL_DEPLOYMENT.md
Tested in k3s, but should work in other Kubernetes environments.


### 1. Prepare Certificates
This assumes you've already set up Kafka and have certs/keys available in the certs directory,
or else have been given certs/keys to connect to an existing environment.
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

### 3. Specify Clickhouse passwords
./schema/
- copy users.sql.example to users.sql
- specify passwords for the adsb_ingest and adsb_query users, replacing "CHANGEME"

### 4. Customize manifests
Some of the manifests require configuration for your environment

./manifests/adsb-clickhouse/
  - 10-secrets-kafka-tls.yaml.example
    - copy to 10-secrets-kafka-tls.yaml
    - populate with the base64-encoded keypair values you created in step 1
  - 30-clickhouse-local.yaml.example
    - copy to 30-clickhouse-local.yaml
    - replace the 3 instances of "lab.url:port" with the appropriate url:port (or comma-separated list) for your Kafka provider
      <kafka_broker_list>lab.url:port</kafka_broker_list>
    - replace <PASSWORD_SHA256> with the SHA256-encoded password for your clickhouse admin account
      (generated with "echo -n mypassword | sha256sum")

./manifests/adsb-monitoring/
  - 20-grafana-config.yaml.example
    - copy to 20-grafana-config.yaml
    - populate passwords for the query and ingest users from step 3

### 5. Customize dashboards
./dashboards/templates/
  - If using the example map dashboards, copy the 3 .json files to dashboards/adsb/
  - in the Global and Local files, replace <LATITUDE> and <LONGITUDE> with the latitude and longitude values for your ADS-B receiver


### Deploy ClickHouse Stack
```bash
1. Install Altinity Clickhouse Operator
curl -s https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator-web-installer/clickhouse-operator-install.sh | bash

# 2. Create namespace
kubectl apply -f manifests/adsb-clickhouse/00-namespace.yaml

# 3. Create secrets (your customized file)
kubectl apply -f manifests/adsb-clickhouse/10-secrets-kafka-tls.yaml

# 4. Deploy Keeper
kubectl apply -f manifests/adsb-clickhouse/20-keeper-local.yaml
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
kubectl apply -f manifests/adsb-monitoring/11-prometheus-local.yaml
kubectl get pods -n adsb-monitoring -w

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
kubectl apply -f manifests/adsb-monitoring/25-grafana-local.yaml
kubectl get pods -n adsb-monitoring -w
```


### Cleanup
Before deleting the adsb-clickhouse namespace:

```bash
NAMESPACE="${1:-adsb-clickhouse}"

echo "Cleaning up namespace: $NAMESPACE"

# Step 1: Delete ClickHouseInstallations (operator processes finalizers while running)
echo "Deleting ClickHouseInstallation resources..."
kubectl delete clickhouseinstallation --all -n $NAMESPACE --timeout=60s

# Step 2: Delete ClickHouseKeeperInstallations if any
echo "Deleting ClickHouseKeeperInstallation resources..."
kubectl delete clickhousekeeperinstallation --all -n $NAMESPACE --timeout=60s --ignore-not-found=true

# Step 3: Wait for operator to finish cleanup
echo "Waiting for operator to finish cleanup..."
sleep 10

# Step 4: Force remove finalizers if any resources are stuck
CHI_STUCK=$(kubectl get clickhouseinstallation -n $NAMESPACE -o name 2>/dev/null)
if [ -n "$CHI_STUCK" ]; then
  echo "Forcing finalizer removal on stuck resources..."
  echo "$CHI_STUCK" | xargs -I {} kubectl patch {} -n $NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge
fi

# Step 5: Delete the namespace
echo "Deleting namespace..."
kubectl delete namespace $NAMESPACE

echo "Cleanup complete"
```