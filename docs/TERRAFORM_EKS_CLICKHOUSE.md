# ADSB EKS Deployment Checklist
This document is deprecated - review docs/ANSIBLE_DEPLOYMENT.md


## Pre-Deployment

- These procedures assume that a Kafka or Redpanda cluster is running and accessible,
and that the required keys were stored in the certs directory (review certs/README.md)

- Copy the manifests/30-clickhouse-eks.yaml.template file to manifests/30-clickhouse-eks.yaml
- Modify each <kafka_broker_list> stanza, replacing the placeholder URL(s) to the FQDN of your Kakfa brokers

- AWS CLI configured with appropriate credentials
  ```bash
  aws configure
  aws sts get-caller-identity
  ```

Required tools installed:
  - Terraform >= 1.6
  - kubectl
  - helm
  - aws-cli


## Infrastructure Deployment (Terraform)

- Initialize Terraform
  ```bash
  cd adsb-eks-terraform
  terraform init
  ```

- Review infrastructure plan
  ```bash
  terraform plan
  # Review: VPC, EKS, node groups, storage, S3 buckets
  ```

- Apply infrastructure (15-20 minutes)
  ```bash
  terraform apply
  # Save outputs
  terraform output > outputs.txt
  ```

- Configure kubectl access
  ```bash
 aws eks update-kubeconfig \
  --region us-east-1 \
  --name adsb-eks-lab \
  --alias eks-lab \
  --kubeconfig ~/.kube/configs/eks-lab
  
- Add .kube config path to bashrc if necessary
export KUBECONFIG=~/.kube/configs/k3s-local:~/.kube/configs/eks-lab

- Verify EBS CSI driver
  kubectl get pods -n kube-system | grep ebs-csi
  kubectl get sc

- Install Altinity Clickhouse Operator
  ```bash
VERSION=$(curl -s https://api.github.com/repos/Altinity/clickhouse-operator/releases/latest | grep '"tag_name"' | sed -E 's/.*"release-([^"]+)".*/\1/')
echo "Installing version: $VERSION"
kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/${VERSION}/deploy/operator/clickhouse-operator-install-bundle.yaml



## Clickhouse Deployment

- Create namespaces
kubectl apply -f ../manifests/clickhouse/00-namespace.yaml

- Create ClickHouse S3 service account (for future backups)
ROLE_ARN=$(terraform output -raw clickhouse_s3_role_arn)

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: clickhouse-s3
  namespace: clickhouse
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

- Exit terraform dir
cd ..

- Deploy Kafka TLS secret
kubectl create secret generic kafka-client-tls \
  --from-file=ca.crt=certs/ca.crt \
  --from-file=client.crt=certs/client.crt \
  --from-file=client.key=certs/client.key \
  -n clickhouse

- Deploy ClickHouse Keeper (3 nodes)
  ```bash
  kubectl apply -f manifests/clickhouse/20-keeper-eks.yaml
  
  # Wait for all 3 Keeper pods
  kubectl wait --for=condition=ready pod \
    -l clickhouse-keeper.altinity.com/chk=adsb-keeper \
    -n clickhouse --timeout=300s
  
  # Verify Keeper cluster
  kubectl get pods -n clickhouse -l clickhouse-keeper.altinity.com/chk=adsb-keeper
  ```

- Deploy ClickHouse cluster (2 shards × 2 replicas = 4 pods)
  ```bash
  kubectl apply -f manifests/clickhouse/30-clickhouse-eks.yaml
  
  # Wait for all 4 ClickHouse pods
  kubectl wait --for=condition=ready pod \
    -l clickhouse.altinity.com/chi=adsb-data \
    -n clickhouse --timeout=600s
  
  # Verify cluster
  kubectl get pods -n clickhouse -l clickhouse.altinity.com/chi=adsb-data
  ```

- Verify ClickHouse cluster status
  ```bash
  # Connect to first pod
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- clickhouse-client
  
  # In clickhouse-client:
  SELECT * FROM system.clusters WHERE cluster = 'adsb-data';
  # Should show 2 shards, 2 replicas each (4 rows total)
  
  # Check Keeper connectivity
  SELECT * FROM system.zookeeper WHERE path = '/';
  # Should return results (Keeper is working)
  ```

  - Get ClickHouse LoadBalancer endpoint
  ```bash
  kubectl get svc clickhouse-adsb-data -n clickhouse
  # Note the EXTERNAL-IP for remote connections
  ```


  ## Schema Deployment

- Prepare schema SQL with cluster-aware commands
  - Add `ON CLUSTER '{cluster}'` to CREATE statements
  - Create distributed tables for cross-shard queries
  - Verify ReplicatedMergeTree table definitions include macros

- Deploy schema
  ```bash
  # Option 1: Via pod
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- clickhouse-client --multiquery < schema/schema.sql
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- lickhouse-client --multiquery < schema/users.sql
  
  # Option 2: Via port-forward
  kubectl port-forward -n clickhouse svc/clickhouse-adsb-data 8123:8123 &
  clickhouse-client --host localhost --port 8123 --multiquery < schema/schema.sql
  clickhouse-client --host localhost --port 8123 --multiquery < schema/users.sql
  ```

- Verify tables created on all nodes
  ```bash
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- \
    clickhouse-client --query "SHOW TABLES"
  
  kubectl exec -it chi-adsb-data-adsb-data-1-0-0 -n clickhouse -- \
    clickhouse-client --query "SHOW TABLES"
  # Should match on all pods
  ```

- Test Kafka connectivity from ClickHouse
  ```bash
  # Check Kafka consumers are active
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- \
    clickhouse-client --query "SELECT * FROM system.kafka_consumers"
  
  # Check if data is flowing
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- \
    clickhouse-client --query "SELECT count() FROM flights_local"
  ```


## Monitoring Deployment

- Deploy Grafana
  ```bash
  kubectl apply -f kubernetes-manifests/15-grafana-config.yaml
  kubectl apply -f kubernetes-manifests/20-grafana.yaml
  
  kubectl wait --for=condition=ready pod -l app=grafana -n monitoring --timeout=300s
  ```

- Get Grafana URL
  ```bash
  kubectl get svc grafana -n monitoring
  # Access at http://<EXTERNAL-IP>
  # Default credentials: admin/admin
  ```

- Deploy Dashboards
kubectl cp ~/dashboards/*.json monitoring/grafana-<pod-id>:/var/lib/grafana/dashboards/

- Verify Grafana datasources
  - Login to Grafana
  - Navigate to Configuration → Data Sources
  - Test both ClickHouse datasources
  - Create test dashboard


  ## Validation

- Verify data ingestion from Kafka
  ```bash
  # Check row counts across all tables
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- \
    clickhouse-client --query "
      SELECT 
        table,
        sum(rows) as total_rows 
      FROM clusterAllReplicas('adsb-data', system.parts) 
      WHERE active 
      GROUP BY table
    "
  ```

- Test cross-shard queries
  ```bash
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- \
    clickhouse-client --query "
      SELECT count() FROM flights_local_dist
    "
  # Should return total across all shards
  ```

- Verify replication is working
  ```bash
  kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- \
    clickhouse-client --query "SELECT * FROM system.replicas"
  # Check is_leader, is_readonly, absolute_delay columns
  ```

- Test failover (optional)
  ```bash
  # Delete one replica
  kubectl delete pod chi-adsb-data-adsb-data-0-0-0 -n clickhouse
  
  # Verify other replica continues serving
  kubectl exec -it chi-adsb-data-adsb-data-0-1-0 -n clickhouse -- \
    clickhouse-client --query "SELECT count() FROM flights_local"
  
  # Wait for deleted pod to recreate and rejoin
  kubectl wait --for=condition=ready pod chi-adsb-data-adsb-data-0-0-0 -n clickhouse --timeout=300s
