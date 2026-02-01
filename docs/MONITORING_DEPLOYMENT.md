# Prometheus and Grafana Monitoring Setup for ClickHouse

This guide walks through adding Prometheus monitoring and the Altinity ClickHouse Operator dashboards to your homelab.

## Overview

The setup includes:
- **Prometheus Operator**: Manages Prometheus instances using CRDs
- **Prometheus**: Scrapes metrics from ClickHouse Operator, ClickHouse servers, and Keeper
- **ServiceMonitors**: Configure what Prometheus scrapes
- **Grafana**: Updated with Prometheus datasource and dashboard provisioning

## Your Deployment Configuration

- **ClickHouse Operator**: `kube-system` namespace, ports 8888, 9999
- **ClickHouse Cluster**: `clickhouse` namespace, CHI name `adsb-data`
- **ClickHouse Keeper**: `clickhouse` namespace, service `adsb-keeper-headless`
- **Grafana**: `monitoring` namespace

## Deployment Steps

### Step 1: Install Prometheus Operator CRDs

The Prometheus Operator requires CRDs to be installed first:

```bash
# Install Prometheus Operator CRDs
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagers.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagerconfigs.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.70.0/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml
```

### Step 2: Deploy Prometheus Operator

```bash
kubectl apply -f 10-prometheus-operator.yaml
```

Wait for the operator to be ready:
```bash
kubectl wait --for=condition=available --timeout=300s deployment/prometheus-operator -n monitoring
```

### Step 3: Deploy Prometheus Instance

```bash
kubectl apply -f 15-prometheus.yaml
```

Wait for Prometheus to be ready:
```bash
kubectl wait --for=condition=ready --timeout=300s prometheus/prometheus -n monitoring
```

### Step 4: Update ClickHouse Operator Service

The ClickHouse Operator service needs named ports for ServiceMonitor to work:

```bash
kubectl patch service clickhouse-operator-metrics -n kube-system --type='json' -p='[
  {"op": "replace", "path": "/spec/ports/0", "value": {"name": "metrics", "port": 8888, "protocol": "TCP", "targetPort": 8888}},
  {"op": "replace", "path": "/spec/ports/1", "value": {"name": "metrics-alt", "port": 9999, "protocol": "TCP", "targetPort": 9999}}
]'
```

Verify the service has named ports:
```bash
kubectl get service clickhouse-operator-metrics -n kube-system -o yaml
```

### Step 5: Enable ClickHouse Server Metrics

Update your ClickHouse installation to enable Prometheus metrics:

```bash
kubectl apply -f 30-clickhouse-with-metrics.yaml
```

This adds:
- Prometheus metrics settings in the configuration
- Port 9363 exposure for metrics
- NodePort 30363 for external access (optional)

Wait for the CHI to be updated:
```bash
kubectl get chi adsb-data -n clickhouse -w
```

Verify metrics are working:
```bash
# Get the ClickHouse pod name
POD=$(kubectl get pod -n clickhouse -l clickhouse.altinity.com/chi=adsb-data -o jsonpath='{.items[0].metadata.name}')

# Test metrics endpoint
kubectl exec -n clickhouse $POD -- curl -s localhost:9363/metrics | head -20
```

You should see output like:
```
# HELP clickhouse_BackgroundPoolTask Number of active tasks in BackgroundProcessingPool
# TYPE clickhouse_BackgroundPoolTask gauge
clickhouse_BackgroundPoolTask 0
...
```

### Step 6: Deploy ServiceMonitors

Deploy ServiceMonitor for ClickHouse Operator:
```bash
kubectl apply -f 30-servicemonitor-operator.yaml
```

Deploy ServiceMonitor for ClickHouse servers:
```bash
kubectl apply -f 31-servicemonitor-clickhouse.yaml
```

### Step 7: Configure Keeper Metrics

Your Keeper is deployed using the ClickHouse Keeper Operator with the following services:
- `adsb-keeper-headless` - Headless service you configured
- `keeper-adsb-keeper` - Operator-managed service with labels `clickhouse-keeper.altinity.com/chk: adsb-keeper`
- `chk-adsb-keeper-adsb-keeper-0-0` - Per-replica service

First, test if Keeper already has metrics enabled:
```bash
./test-keeper-metrics.sh
```

**If metrics are NOT available**, you need to enable them in your ClickHouseKeeperInstallation manifest:

1. View your current Keeper installation:
   ```bash
   kubectl get chk adsb-keeper -n clickhouse -o yaml > current-keeper.yaml
   ```

2. Add Prometheus metrics configuration to the spec:
   ```yaml
   spec:
     configuration:
       settings:
         prometheus.port: 9234
         prometheus.endpoint: /metrics
         prometheus.metrics: "true"
         prometheus.asynchronous_metrics: "true"
   ```

3. Add the Prometheus port to your pod and service templates:
   ```yaml
   templates:
     podTemplates:
       - name: keeper-pod
         spec:
           containers:
             - name: clickhouse-keeper
               ports:
                 - name: prometheus
                   containerPort: 9234
                   protocol: TCP
     
     serviceTemplates:
       - name: keeper-service
         spec:
           ports:
             - name: prometheus
               port: 9234
               targetPort: 9234
   ```

4. Apply the updated manifest:
   ```bash
   kubectl apply -f <your-updated-keeper-manifest.yaml>
   ```

5. Wait for Keeper to be updated and verify metrics:
   ```bash
   ./test-keeper-metrics.sh
   ```

**If metrics ARE available**, note which port they're on (likely 9234, 9181, or 9182) and deploy the ServiceMonitor:

```bash
# If using a different port than 9234, update 32-servicemonitor-keeper.yaml first
kubectl apply -f 32-servicemonitor-keeper.yaml
```

**Note**: See `40-keeper-with-metrics-example.yaml` for a complete example of a Keeper installation with metrics enabled.

### Step 8: Update Grafana Datasources

The datasource configuration includes:
- **ClickHouse (vertamedia plugin)** - Primary datasource for Altinity dashboard and system table queries
- **Prometheus** - For operator metrics and real-time monitoring

Create a secret for the ClickHouse password:
```bash
kubectl create secret generic grafana-secrets \
  --from-literal=clickhouse-password='YOUR_ADMIN_PASSWORD_HERE' \
  -n monitoring
```

Apply the updated datasource configuration:
```bash
kubectl apply -f 10-grafana-config.yaml
```

**Note:** The config uses `vertamedia-clickhouse-datasource` which is what the Altinity dashboard expects. See `DATASOURCE-GUIDE.md` for details on when to use ClickHouse vs Prometheus datasources.

### Step 9: Download Altinity Dashboard

```bash
./download-altinity-dashboard.sh
```

This downloads the Altinity ClickHouse Operator Dashboard JSON file.

### Step 10: Create Dashboard ConfigMap

```bash
kubectl create configmap clickhouse-dashboards \
  --from-file=altinity-clickhouse-operator-dashboard.json \
  -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 11: Update Grafana Deployment

```bash
kubectl delete deployment grafana -n monitoring
kubectl apply -f 20-grafana-updated.yaml
```

Note: We delete the deployment first because we're changing from Deployment to StatefulSet (if needed) or to ensure clean restart with new volume mounts.

### Step 12: Verify Everything

Check Prometheus targets:
```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090
```

Then visit http://localhost:9090/targets to see all scrape targets. You should see:
- `serviceMonitor/kube-system/clickhouse-operator/0` (port 8888)
- `serviceMonitor/kube-system/clickhouse-operator/1` (port 9999)
- `serviceMonitor/clickhouse/clickhouse-servers/0` (port 9363)
- `serviceMonitor/clickhouse/clickhouse-keeper/0` (if configured)

Check Grafana:
```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```

Visit http://localhost:3000 and:
1. Check that Prometheus datasource is configured (Configuration → Data Sources)
2. Check that ClickHouse datasource is configured
3. Look for the "ClickHouse" folder with the Altinity dashboard
4. Verify the dashboard loads and shows data

Access Prometheus metrics externally (optional):
```bash
# ClickHouse metrics on NodePort
curl http://<node-ip>:30363/metrics

# Prometheus on NodePort
curl http://<node-ip>:32090
```

## Troubleshooting

### Prometheus not scraping operator

Check if the ServiceMonitor is being picked up:
```bash
kubectl get servicemonitor -A
kubectl describe servicemonitor clickhouse-operator -n kube-system
```

Verify the Prometheus instance selector matches:
```bash
kubectl get prometheus prometheus -n monitoring -o yaml | grep -A 5 serviceMonitorSelector
```

Check Prometheus logs:
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus -f
```

### No metrics showing in Grafana

1. Check Prometheus targets: `kubectl port-forward -n monitoring svc/prometheus 9090:9090`
2. Verify metrics are being scraped: Look at Status → Targets
3. Check that datasource is working in Grafana (should show green checkmark)
4. Query Prometheus directly to verify data:
   ```
   clickhouse_BackgroundPoolTask
   clickhouse_operator_chi_count
   ```

### ClickHouse server metrics not appearing

1. Verify metrics are enabled in ClickHouse:
   ```bash
   kubectl exec -n clickhouse $POD -- clickhouse-client -q "SELECT * FROM system.metrics LIMIT 5"
   ```

2. Check if the metrics port is exposed:
   ```bash
   kubectl exec -n clickhouse $POD -- curl localhost:9363/metrics | head
   ```

3. Verify ServiceMonitor labels match the service:
   ```bash
   # Get service labels
   kubectl get svc -n clickhouse -l clickhouse.altinity.com/chi=adsb-data -o yaml | grep -A 5 labels
   
   # Get ServiceMonitor selector
   kubectl get servicemonitor clickhouse-servers -n clickhouse -o yaml | grep -A 5 selector
   ```

4. Check service has the metrics port:
   ```bash
   kubectl get svc -n clickhouse -l clickhouse.altinity.com/chi=adsb-data -o yaml | grep -A 10 "ports:"
   ```

### Keeper metrics issues

1. Verify Keeper is running:
   ```bash
   kubectl get pods -n clickhouse -l clickhouse-keeper.altinity.com/chk=adsb-keeper
   ```

2. Test metrics endpoint manually:
   ```bash
   ./test-keeper-metrics.sh
   ```

3. Check Keeper configuration for Prometheus settings:
   ```bash
   KEEPER_POD=$(kubectl get pod -n clickhouse -l clickhouse-keeper.altinity.com/chk=adsb-keeper -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -n clickhouse $KEEPER_POD -- cat /etc/clickhouse-keeper/keeper_config.xml | grep -i prometheus
   ```

4. Check if the Keeper service has the Prometheus port:
   ```bash
   kubectl get svc keeper-adsb-keeper -n clickhouse -o yaml | grep -A 5 "ports:"
   ```

5. Verify ServiceMonitor is targeting the correct service:
   ```bash
   # Check ServiceMonitor selector
   kubectl get servicemonitor clickhouse-keeper -n clickhouse -o yaml | grep -A 5 selector
   
   # Check Keeper service labels
   kubectl get svc keeper-adsb-keeper -n clickhouse -o yaml | grep -A 10 labels
   ```

6. If Keeper doesn't have metrics enabled, see `40-keeper-with-metrics-example.yaml` for an example configuration.

## Files Created

- `10-prometheus-operator.yaml` - Prometheus Operator deployment
- `15-prometheus.yaml` - Prometheus instance and RBAC
- `30-servicemonitor-operator.yaml` - ServiceMonitor for ClickHouse Operator
- `31-servicemonitor-clickhouse.yaml` - ServiceMonitor for ClickHouse servers
- `32-servicemonitor-keeper.yaml` - ServiceMonitor for Keeper
- `30-clickhouse-with-metrics.yaml` - Updated CHI with Prometheus metrics enabled
- `40-keeper-with-metrics-example.yaml` - Example Keeper manifest with metrics
- `10-grafana-config.yaml` - Updated datasources (vertamedia + Prometheus)
- `20-grafana-updated.yaml` - Updated Grafana with dashboard provisioning
- `download-altinity-dashboard.sh` - Script to download Altinity dashboard
- `check-keeper-deployment.sh` - Helper script to identify Keeper configuration
- `test-keeper-metrics.sh` - Script to test Keeper metrics endpoints
- `DEPLOYMENT-GUIDE.md` - Complete deployment walkthrough
- `METRICS-REFERENCE.md` - Guide to useful ClickHouse and Keeper metrics
- `DATASOURCE-GUIDE.md` - When to use ClickHouse vs Prometheus datasources

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Monitoring Namespace                     │
│                                                              │
│  ┌──────────────┐         ┌────────────────┐               │
│  │  Prometheus  │────────▶│    Grafana     │               │
│  │   Operator   │         │                │               │
│  └──────────────┘         └────────────────┘               │
│         │                          │                        │
│         │                          │                        │
│         ▼                          │                        │
│  ┌──────────────┐                 │                        │
│  │  Prometheus  │                 │                        │
│  │   Instance   │                 │                        │
│  └──────┬───────┘                 │                        │
│         │  ▲                      │                        │
└─────────┼──┼──────────────────────┼────────────────────────┘
          │  │                      │
          │  │                      │
┌─────────┼──┼──────────────────────┼────────────────────────┐
│         │  │  kube-system         │                        │
│         │  │                      │                        │
│         │  └──────────────────────┼─────────────           │
│         │  ServiceMonitor         │                        │
│         │                         │                        │
│         ▼                         │                        │
│  ┌──────────────┐                │                        │
│  │  ClickHouse  │                │                        │
│  │   Operator   │                │                        │
│  │ (ports 8888, │                │                        │
│  │      9999)   │                │                        │
│  └──────────────┘                │                        │
└──────────────────────────────────┼────────────────────────┘
                                   │
┌──────────────────────────────────┼────────────────────────┐
│         │  clickhouse            │                        │
│         │                        │                        │
│         └────────────────────────┼─────────────           │
│            ServiceMonitor        │                        │
│                                  │                        │
│         ┌──────────────┐         │                        │
│         │  ClickHouse  │         │                        │
│         │   Cluster    │         │                        │
│         │ (port 9363)  │         │                        │
│         └──────────────┘         │                        │
│                                  │                        │
│         ┌──────────────┐         │                        │
│         │   Keeper     │         │                        │
│         │(port 9181/2) │         │                        │
│         └──────────────┘         │                        │
└──────────────────────────────────┴────────────────────────┘
```

