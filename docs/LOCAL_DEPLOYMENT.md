# Local K3S Deployment Checklist
These procedures cover manual local deployment of a lab environment, including
the kafka cluster and scraper/producer pods.  They were tested in k3s, but should
work in other Kubernetes environments.


### 1. Prepare Certificates
Review procedures in certs/README.md

### 2. Create Kafka Secrets
Copy manifests/kafka/10-secrets.yaml.example to manifests/kafka/10-secrets.yaml
and populate with base64-encoded values (from step 1)

### 3. Configure Scrapers
Copy manifests/scrapers/10-configmap.yaml.example manifests/scrapers/10-configmap.yaml
and edit as appropriate for your location

Key values to update:
- `LOCAL_URL`: Your local ADS-B receiver endpoint
- `REGIONAL_URL`: Customize lat/lon/radius for your location
- `KAFKA_BROKERS`: Should be correct as-is for k3s

### 4. Apply lables to Nodes



## Deployment

### Deploy Kafka Stack

```bash
# 1. Create namespace
kubectl apply -f manifests/kafka/00-namespace.yaml

# 2. Create secrets (your customized file)
kubectl apply -f manifests/kafka/10-secrets.yaml

# 3. Deploy Zookeeper
kubectl apply -f manifests/kafka/20-zookeeper.yaml

# 4. Wait for Zookeeper to be ready
kubectl -n kafka wait --for=condition=ready pod -l app=zookeeper --timeout=300s

# 5. Deploy Kafka
kubectl apply -f manifests/kafka/02-kafka.yaml

# 6. Wait for Kafka to be ready
kubectl -n kafka wait --for=condition=ready pod -l app=kafka --timeout=300s
```

### Deploy Scrapers

```bash
# 1. Create namespace
kubectl apply -f manifests/scrapers/00-namespace.yaml

# 2. Create ConfigMap (your customized file)
kubectl apply -f manifests/scrapers/10-configmap.yaml

# 3. Deploy all scrapers
kubectl apply -f manifests/scrapers/20-deployments.yaml
```

## Verification

### Check Kafka and Zookeeper

```bash
# View all Kafka resources
kubectl -n kafka get all,pvc

# Check Kafka logs
kubectl -n kafka logs kafka-0 | tail -50

# Check Zookeeper logs
kubectl -n kafka logs zookeeper-0

# Verify external service
kubectl -n kafka get svc kafka-external
```

### Check Scrapers

```bash
# View all scraper resources
kubectl -n scrapers get all

# Check which scrapers are running
kubectl -n scrapers get pods -l app=adsb-scraper

# View logs for specific scraper
kubectl -n scrapers logs -l source=local --tail=100
kubectl -n scrapers logs -l source=global --tail=100

# Follow logs in real-time
kubectl -n scrapers logs -l source=local -f

# Check ConfigMap
kubectl -n scrapers get cm scraper-config -o yaml
```

### Test Kafka Connectivity

```bash
# Test internal connectivity from within cluster
kubectl run -n kafka kafka-test --rm -it --image=apache/kafka:3.9.0 -- bash
# Inside pod:
/opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-0.kafka-headless.kafka.svc.cluster.local:9092 --list

# Test external TLS connectivity (requires client certs)
openssl s_client -connect lab.apgar.us:30192 \
  -cert client.crt -key client.key -CAfile ca.crt
```

## Making Changes

### Update Kafka Configuration

Edit the server.properties inline configuration in `manifests/kafka/20-kafka.yaml`:
- Retention settings
- Partition counts
- Resource limits
- External advertised listener

Apply changes:
```bash
kubectl apply -f manifests/kafka/20-kafka.yaml
kubectl -n kafka rollout restart statefulset kafka
```

### Update Scraper Configuration

Edit `manifests/scrapers/10-configmap.yaml` and redeploy:
```bash
kubectl apply -f manifests/scrapers/10-configmap.yaml
kubectl -n scrapers rollout restart deployment
```

### Enable/Disable Scrapers

Edit the `replicas` field in `manifests/scrapers/20-deployments.yaml`:
- `replicas: 1` - Scraper enabled
- `replicas: 0` - Scraper disabled

Apply changes:
```bash
kubectl apply -f manifests/scrapers/20-deployments.yaml
```

### Update Scraper Image
```bash
# Rebuild and import to k3s
cd ~/adsb-scraper
docker build -t adsb-scraper:latest .
docker save adsb-scraper:latest | sudo k3s ctr images import -

# Force pods to restart and pull new image
kubectl -n scrapers rollout restart deployment
```
For AWS deployment, you'll want to push this to a registry (ECR or Docker Hub)

## Customization for Different Environments

### k3s → AWS/EKS Changes

When deploying to AWS, you'll need to update:

**Kafka manifests:**
1. `storageClassName`: `local-path` → `gp3` (or your EBS storage class)
2. `nodeSelector`: Remove or change to appropriate EKS node selector
3. External service: Change from `NodePort` to `LoadBalancer`
4. `advertised.listeners`: Update EXTERNAL to point to AWS load balancer DNS

**Scraper manifests:**
1. `image`: `adsb-scraper:latest` → `<account>.dkr.ecr.<region>.amazonaws.com/adsb-scraper:latest`
2. `nodeSelector`: Remove or change to appropriate EKS node selector
3. `imagePullPolicy`: Consider changing to `Always` for registry-based images
4. `KAFKA_BROKERS` in ConfigMap: Update if Kafka cluster DNS changes


### OPTIONAL: Set up Clickhouse and Grafana
If you are planning on hosting Clickhouse locally rather than in EKS:

- copy manifests/10-secrets-kafka-tls.yaml.example to 10-secrets-kafka-tls.yaml
- populate with the base64-encoded keypair values from step 1
- copy schema/users.sql.example to schema/users.sql
- update the passwords for the query and ingest users
- copy manifests/10-grafana-config.yaml.example to 10-grafana-config.yaml
- populate passwords for the query and ingest users
- copy manifests/30-clickhouse.yaml.example to 30-clickhouse.yaml
- update the kafka broker lists, and the admin user password_sha256_hex
- apply labels to nodes
- apply the following manifests
    - manifests/clickhouse/00-namespace.yaml
    - manifests/clickhouse/10-secrets-kafka-tls.yaml
    - manifests/clickhouse/20-keeper.yaml
    - manifests/clickhouse/30-clickhouse.yaml
    - manifests/monitoring/00-namespace.yaml
    - manifests/monitoring/10-grafana-config.yaml
    - manifests/monitoring/20-grafana.yaml
- copy 

## Directory Structure

```
.
├── README.md                           # This file
├── .gitignore                          # Protects secrets and configs
├── certs/                              # Keystores (gitignored)
│   ├── server.keystore.jks
│   └── server.truststore.jks
├── manifests/
│   ├── kafka/
│   │   ├── 00-namespace.yaml
│   │   ├── 00-secrets.yaml.example    # Template (committed)
│   │   ├── 00-secrets.yaml            # Your config (gitignored)
│   │   ├── 01-zookeeper.yaml
│   │   └── 02-kafka.yaml
│   └── scrapers/
│       ├── 00-namespace.yaml
│       ├── 01-configmap.yaml.example  # Template (committed)
│       ├── 01-configmap.yaml          # Your config (gitignored)
│       └── 02-deployments.yaml
└── docs/
    └── DEPLOYMENT.md                   # This file (symlinked from README.md)
```

## Troubleshooting

### Kafka won't start

```bash
# Check Zookeeper is ready
kubectl -n kafka get pods

# View Kafka logs for errors
kubectl -n kafka logs kafka-0

# Common issues:
# - Zookeeper not ready: Wait longer or check Zookeeper logs
# - Certificate problems: Verify secrets contain valid base64-encoded JKS files
# - Node selector mismatch: Ensure node label matches nodeSelector
```

### Scrapers can't connect to Kafka

```bash
# Verify Kafka internal service is accessible
kubectl -n kafka get svc kafka-headless

# Check scraper logs for connection errors
kubectl -n scrapers logs -l app=adsb-scraper

# Verify ConfigMap has correct broker address
kubectl -n scrapers get cm scraper-config -o yaml

# Test connectivity from scraper namespace
kubectl run -n scrapers test --rm -it --image=busybox -- sh
# Inside pod:
nc -zv kafka-0.kafka-headless.kafka.svc.cluster.local 9092
```

### PVCs stuck in Pending

```bash
# Check storage class exists
kubectl get storageclass

# For k3s, verify local-path-provisioner is running
kubectl -n kube-system get pods -l app=local-path-provisioner

# Check if node has available capacity
kubectl describe node k3s-vm2

# View PVC events for more details
kubectl -n kafka describe pvc
```

### External Kafka access not working

```bash
# Verify NodePort service is exposed
kubectl -n kafka get svc kafka-external

# Check if port 30192 is reachable from outside
nc -zv lab.apgar.us 30192

# Verify firewall allows traffic on NodePort
# Verify DNS resolves to correct IP
dig lab.apgar.us

# Test TLS handshake (requires client certs)
openssl s_client -connect lab.apgar.us:30192 \
  -cert client.crt -key client.key -CAfile ca.crt
```


## Publishing Scraper Image

For AWS deployment, you'll need to publish the scraper image:

### Option 1: AWS ECR
```bash
# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com

# Tag and push
docker tag adsb-scraper:latest <account>.dkr.ecr.us-east-1.amazonaws.com/adsb-scraper:latest
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/adsb-scraper:latest
```

### Option 2: Docker Hub
```bash
# Tag and push
docker tag adsb-scraper:latest <username>/adsb-scraper:latest
docker push <username>/adsb-scraper:latest
```

Then update `image:` field in `manifests/scrapers/02-deployments.yaml`.

