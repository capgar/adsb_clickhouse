# Local K3S Deployment Checklist
These procedures cover manual local deployment of a lab environment, including
the kafka cluster and scraper/producer pods.  They were tested in k3s, but should
work in other Kubernetes environments.


### 1. Prepare Certificates
Review procedures in ./docs/KAFKA_CERTS.md

### 2. Create Kafka Secrets
Copy manifests/adsb-kafka/10-secrets.yaml.example to manifests/adsb-kafka/10-secrets.yaml
and populate with base64-encoded values (from step 1)

### 4. Customize manifests
./manifests/adsb-kafka/30-kafka-single.yaml.example
or
./manifests/adsb-kafka/30-kafka-pair.yaml.example
  - copy to 30-kafka-(single|pair).yaml
  - replace instances of "lab.url" to the correct url for your kafka cluster

./manifests/adsb-collectors/30-scrapers.yaml.example
  - copy to 30-scrapers.yaml
  - enable or disable individual scraper deployments by setting replicas to 1 (default) or 0 (disabled)
  - in the Regional Scraper section, replace <LAT> and <LON> in SOURCE_URL to reflect your receiver coordinates
  - update POLL_INTERVAL for scrapers as desired

### 5. Apply lables to Nodes (optional)
We can steer workloads to nodes using a combination of preferred scheduling and taints/tolerations.
For namespaces with multiple component types (clickhouse and kafka), the workload values define each component:
- adsb-kafka (or adsb-kafka-0, adsb-kafka-1 for a pair)
- adsb-kafka-zk
- adsb-collectors

Example: To steer both Kafka and Zookeeper resources to the same node(s):
kubectl label nodes <node-name> adsb-kafka=true adsb-kafka-zk=true

Removing a label:
kubectl label nodes <node-name> adsb-collectors-

Check node labels:
kubectl get nodes --show-labels
kubectl get nodes -l adsb-collectors=true

### 6. Build Scraper Image
Log on to any kubernetes nodes which are labeled to run adsb-collectors
mkdir -p ~/adsb-scraper
cd ~/adsb-scraper
docker build -t adsb-scraper:latest .
docker save adsb-scraper:latest | sudo k3s ctr images import -


## Deployment

### Deploy Kafka Stack
```bash
# 1. Create secrets (your customized file)
kubectl apply -f manifests/adsb-kafka/10-secrets.yaml

# 2. Deploy Zookeeper and wait for it to be ready
kubectl apply -f manifests/adsb-kafka/20-zookeeper.yaml
kubectl -n adsb-kafka wait --for=condition=ready pod -l app=zookeeper --timeout=300s

# 3. Deploy Kafka and wait for it to be ready
kubectl apply -f manifests/adsb-kafka/30-kafka.yaml
kubectl -n adsb-kafka wait --for=condition=ready pod -l app=kafka --timeout=300s
```

### Deploy Collectors
```bash
# 1. Create ConfigMap (your customized file)
kubectl apply -f manifests/adsb-collectors/10-configmap.yaml

# 2. Deploy readsb streamers
kubectl apply -f manifests/adsb-collectors/20-readsb-adsbhub-client.yaml
kubectl apply -f manifests/adsb-collectors/25-readsb-adsblol-client.yaml

# 3. Deploy scrapers
kubectl apply -f manifests/adsb-collectors/30-scrapers.yaml
kubectl get pods -o wide -n adsb-collectors
```
If the namespace deletion is stuck waiting for a resource which has already been deleted, manually delete it.  Example:
```
NamespaceDeletionDiscoveryFailure            True    Mon, 09 Feb 2026 17:23:08 -0500  DiscoveryFailed         Discovery failed for some groups, 1 failing: unable to retrieve the complete list of server APIs: metrics.k8s.io/v1beta1: stale GroupVersion discovery: metrics.k8s.io/v1beta1

kubectl get apiservice v1beta1.metrics.k8s.io
NAME                     SERVICE                      AVAILABLE                  AGE
v1beta1.metrics.k8s.io   kube-system/metrics-server   False (MissingEndpoints)   30d

kubectl delete apiservice v1beta1.metrics.k8s.io
```


## Verification

### Check Kafka and Zookeeper
```bash
# View all Kafka resources
kubectl -n adsb-kafka get all,pvc

# Check Kafka logs
kubectl -n adsb-kafka logs kafka-0 | tail -50

# Check Zookeeper logs
kubectl -n adsb-kafka logs zookeeper-0

# Verify external service
kubectl -n adsb-kafka get svc kafka-external
```

### Check Collectors
```bash
# View all scraper resources
kubectl -n adsb-collectors get all

# Check which scrapers are running
kubectl -n adsb-collectors get pods -l app=adsb-scraper

# View logs for specific scraper
kubectl -n adsb-collectors logs -l source=local --tail=100
kubectl -n adsb-collectors logs -l source=global --tail=100

# Follow logs in real-time
kubectl -n adsb-collectors logs -l source=local -f

# Check ConfigMap
kubectl -n adsb-collectors get cm scraper-config -o yaml
```

### Test Kafka Connectivity
```bash
# Test internal connectivity from within cluster
kubectl run -n adsb-kafka kafka-test --rm -it --image=apache/kafka:3.9.0 -- bash
# Inside pod:
/opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-0.kafka-headless.kafka.svc.cluster.local:9092 --list

# Test external TLS connectivity (requires client certs)
openssl s_client -connect <kafka_url>:<kafka_port> \
  -cert client.crt -key client.key -CAfile ca.crt
```

## Making Changes

### Update Kafka Configuration
bash
Edit the server.properties inline configuration in `manifests/kafka/20-kafka.yaml`:
- Retention settings
- Partition counts
- Resource limits
- External advertised listener

```bash
# Apply changes:
kubectl apply -f manifests/adsb-kafka/20-kafka.yaml
kubectl -n adsb-kafka rollout restart statefulset kafka
```

### Update Scraper Configuration
```bash
#Edit `manifests/adsb-scrapers/10-configmap.yaml` and redeploy:
kubectl apply -f manifests/adsb-scrapers/10-configmap.yaml
kubectl -n adsb-scrapers rollout restart deployment
```

### Enable/Disable Scrapers

Edit the `replicas` field in `manifests/adsb-scrapers/20-deployments.yaml`:
- `replicas: 1` - Scraper enabled
- `replicas: 0` - Scraper disabled

Apply changes:
kubectl apply -f manifests/adsb-scrapers/20-deployments.yaml


### Update Scraper Image
# Rebuild and import to k3s
cd ~/adsb-scraper
docker build -t adsb-scraper:latest .
docker save adsb-scraper:latest | sudo k3s ctr images import -

# Force pods to restart and pull new image
kubectl -n adsb-scrapers rollout restart deployment

For AWS deployment, you'll want to push this to a registry (ECR or Docker Hub)


## Troubleshooting

### Kafka won't start
```bash
# Check Zookeeper is ready
kubectl -n adsb-kafka get pods

# View Kafka logs for errors
kubectl -n adsb-kafka logs kafka-0

# Common issues:
# - Zookeeper not ready: Wait longer or check Zookeeper logs
# - Certificate problems: Verify secrets contain valid base64-encoded JKS files
# - Node selector mismatch: Ensure node label matches nodeSelector
```

### Scrapers can't connect to Kafka
```bash
# Verify Kafka internal service is accessible
kubectl -n adsb-kafka get svc kafka-headless

# Check scraper logs for connection errors
kubectl -n adsb-collectors logs -l app=adsb-scraper

# Verify ConfigMap has correct broker address
kubectl -n adsb-collectors get cm scraper-config -o yaml

# Test connectivity from scraper namespace
kubectl run -n adsb-collectors test --rm -it --image=busybox -- sh
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
kubectl -n adsb-kafka describe pvc
```

### External Kafka access not working
```bash
# Verify NodePort service is exposed
kubectl -n adsb-kafka get svc kafka-external

# Check if port 30192 is reachable from outside
nc -zv lab.url 30192

# Verify firewall allows traffic on NodePort
# Verify DNS resolves to correct IP
dig lab.url

# Test TLS handshake (requires client certs)
openssl s_client -connect lab.url:30192 \
  -cert client.crt -key client.key -CAfile ca.crt
```

## Publishing Scraper Image

For AWS deployment, you'll need to publish the scraper image:

### Option 1: AWS ECR
# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com

# Tag and push
docker tag adsb-scraper:latest <account>.dkr.ecr.us-east-1.amazonaws.com/adsb-scraper:latest
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/adsb-scraper:latest


### Option 2: Docker Hub

# Tag and push
docker tag adsb-scraper:latest <username>/adsb-scraper:latest
docker push <username>/adsb-scraper:latest

Then update `image:` field in `manifests/adsb-scrapers/20-deployments.yaml`.

