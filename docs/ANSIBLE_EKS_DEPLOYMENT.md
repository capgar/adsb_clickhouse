# ADSB ClickHouse Ansible Automation

Ansible playbooks for automating ADSB ClickHouse deployment to AWS EKS.


## Prerequisites

### 1. Ansible installed (tested with Ansible 2.9+)

### 2. Required tools (validated by playbook):
  - terraform >= 1.6
  - kubectl
  - aws-cli
  - helm

### 3. AWS credentials configured:
  aws configure

  test with:
  aws sts get-caller-identity

### 4. TLS Certificates
If you are hosting your own Kafka/Redpanda cluster and followed the ensure that the base64 encoded certs and keys are available in the certs directory
in base64 encoded format (see docs/KAFKA_CERTS.md)
./certs/ca.crt.b64
./certs/client.crt.b64
./certs/client.key.b64

Alternatively, if you are connecting to an external kafka cluster using MTLS, you will need the values from the above files.

### 5. Users Schema File
./schema/
- copy users.sql.example to users.sql
- specify passwords for the adsb_ingest and adsb_query users, replacing "CHANGEME"

### 6. Customize Manifests
Some of the manifests require configuration for your environment

./manifests/adsb-clickhouse/
  - 10-secrets-kafka-tls.yaml.example
    - copy to 10-secrets-kafka-tls.yaml
    - populate with the base64-encoded keypair values from step 4
  - 30-clickhouse-eks.yaml.example
    - copy to 30-clickhouse-eks.yaml
    - replace the 3 instances of "lab.url:port" with the appropriate url:port (or comma-separated list) for your Kafka provider
      <kafka_broker_list>lab.url:port</kafka_broker_list>
    - replace <PASSWORD_SHA256> with the SHA256-encoded password for your clickhouse admin account
      (generated with "echo -n mypassword | sha256sum")

./manifests/adsb-monitoring/
  - 20-grafana-config.yaml.example
    - copy to 20-grafana-config.yaml
    - populate passwords for the query and ingest users from step 3

### 7. Customize dashboards
./dashboards/examples/
  - If using the example map dashboards, copy the 3 .json files to ../adsb/
  - in the Global and Local files, replace <LATITUDE> and <LONGITUDE> with the latitude and longitude values for your ADS-B receiver


## Configuration

### Update Inventory

Copy `./adsb-ansible/inventory/eks.yml.template` to `./adsb-ansible/inventory/eks.yml`,
and edit eks.yml to match your directory structure:

```yaml
all:
  vars:
    project_root: "{{ playbook_dir }}/.."  # Adjust if needed
    terraform_dir: "{{ project_root }}/adsb-eks-terraform"
    manifests_dir: "{{ project_root }}/manifests/clickhouse"
    # ... etc
```

### Update Variables

Copy `group_vars/eks.yml.template` to `group_vars/eks.yml`,
and edit eks.yml to customize deployment:

```yaml
aws_region: us-east-1           # Your AWS region
eks_cluster_name: adsb-eks-lab  # Your cluster name
clickhouse_shards: 2            # Number of shards
clickhouse_replicas: 2          # Replicas per shard
...
# Monitoring Configuration
grafana_admin_user: admin
grafana_admin_password: "YOUR_SECURE_PASSWORD_HERE"  # Change this!
clickhouse_query_password: "YOUR_CLICKHOUSE_PASSWORD_HERE"  # Change this!
```

## Usage

### Full Deployment

Deploy everything (infrastructure + applications):

```bash
cd adsb-ansible
ansible-playbook -i inventory/eks.yml site.yml
```
During terraform apply phase, automation currently outputs ASYNC POLL lines.  To see in more detail
what terraform is doing, in another terminal tail -f /tmp/terraform-apply.log

### Partial Deployment

Use tags to run specific phases:

```bash
# Only infrastructure
ansible-playbook -i inventory/eks.yml site.yml --tags infra

# Only ClickHouse (skip Terraform)
ansible-playbook -i inventory/eks.yml site.yml --tags clickhouse

# Only schema
ansible-playbook -i inventory/eks.yml site.yml --tags schema

# Only monitoring
ansible-playbook -i inventory/eks.yml site.yml --tags grafana
```

Available tags:
- `preflight` - Pre-deployment checks
- `infra` - Terraform deployment
- `terraform` - Same as infra
- `kubectl` - kubectl configuration
- `operators` - Install ClickHouse operators
- `clickhouse` - Deploy ClickHouse cluster
- `schema` - Deploy database schema
- `monitoring` / `grafana` - Deploy Grafana
- `validate` - Validation checks

### Skip Phases

Skip specific phases:

```bash
# Skip validation
ansible-playbook -i inventory/eks.yml site.yml --skip-tags validate

# Skip infrastructure (if already deployed)
ansible-playbook -i inventory/eks.yml site.yml --skip-tags infra
```

### Destroy Everything

Tear down the entire deployment:

```bash
ansible-playbook -i inventory/eks.yml destroy.yml
```

This will:
1. Delete all Kubernetes resources
2. Wait for LoadBalancers/PVCs to clean up
3. Run `terraform destroy`
4. Clean up kubectl config

## Workflow Examples

### Initial Deployment

```bash
# 1. Deploy everything
ansible-playbook -i inventory/eks.yml site.yml

Note: for additional details on the progress of the terraform apply, tail /tmp/terraform-apply.log in another terminal

# 2. Access Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80

# 3. Import dashboards (if not automated)
# Upload your .json files via Grafana UI
```

### Update Schema Only

```bash
# Edit your schema files
vim ../schema/schema.sql

# Redeploy schema
ansible-playbook -i inventory/eks.yml site.yml --tags schema
```

### Update ClickHouse Configuration

```bash
# Edit manifests
vim ../manifests/clickhouse/30-clickhouse-eks.yaml

# Redeploy ClickHouse (will trigger rolling update)
ansible-playbook -i inventory/eks.yml site.yml --tags clickhouse
```

### Validate Deployment

```bash
# Run validation checks only
ansible-playbook -i inventory/eks.yml site.yml --tags validate
```

## Customization

### Adding Custom Steps

Create a new playbook in `playbooks/`:

```yaml
# playbooks/08-custom-step.yml
---
- name: My custom step
  block:
    - name: Do something
      command: echo "Custom step"
```

Then include it in `site.yml`:

```yaml
- name: Custom step
  include_tasks: playbooks/08-custom-step.yml
  tags: [custom]
```

### Environment-Specific Variables

Create additional variable files:

```yaml
# group_vars/eks-staging.yml
eks_cluster_name: adsb-eks-staging
clickhouse_shards: 1
clickhouse_replicas: 1
```

Use with:

```bash
ansible-playbook -i inventory/eks.yml site.yml -e @group_vars/eks-staging.yml
```

## Troubleshooting

### Terraform Failures

If Terraform fails mid-apply:

```bash
# Run Terraform manually to fix
cd ../adsb-eks-terraform
terraform apply

# Then continue Ansible from next step
ansible-playbook -i inventory/eks.yml site.yml --skip-tags terraform
```

### Schema Deployment Issues

The schema playbook uses `kubectl exec` with heredocs which can be tricky. Alternative:

```bash
# Deploy schema manually
kubectl exec -it chi-adsb-data-adsb-data-0-0-0 -n clickhouse -- \
  clickhouse-client --multiquery < ../schema/schema.sql
```

### Dashboard Upload

Stock dashbards are uploaded by the playbook.  For manual upload:

```bash
POD=$(kubectl get pods -n monitoring -l app=grafana -o jsonpath='{.items[0].metadata.name}')
kubectl cp ../dashboards/my-dashboard.json monitoring/$POD:/var/lib/grafana/dashboards/
```


## Support

**Timeouts**: Adjust timeout values in `group_vars/eks.yml` if your deployment is slower:
   ```yaml
   terraform_timeout: 1800  # Increase if needed
   pod_ready_timeout: 900   # Increase if pods are slow
   ```
  
For issues with:
- **Terraform**: Check `../adsb-eks-terraform/`
- **Kubernetes manifests**: Check `../manifests/clickhouse/`
- **ClickHouse**: Check operator logs: `kubectl logs -n kube-system -l app=clickhouse-operator`

### Check Prometheus targets
kubectl port-forward -n adsb-monitoring svc/prometheus 9090:9090
http://localhost:9090/targets