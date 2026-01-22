# ADSB ClickHouse Ansible Automation

Ansible playbooks for automating ADSB ClickHouse deployment to AWS EKS.

## Directory Structure

```
adsb-ansible/
├── site.yml                    # Main deployment playbook
├── destroy.yml                 # Teardown playbook
├── inventory/
│   └── eks.yml                 # Inventory for EKS deployment
├── group_vars/
│   └── eks.yml                 # Variables for EKS environment
├── playbooks/
│   ├── 00-preflight-checks.yml       # Validate prerequisites
│   ├── 01-deploy-infrastructure.yml  # Terraform deployment
│   ├── 02-configure-kubectl.yml      # kubectl setup
│   ├── 03-install-operators.yml      # ClickHouse operators
│   ├── 04-deploy-clickhouse.yml      # ClickHouse cluster
│   ├── 05-deploy-schema.yml          # Schema deployment
│   ├── 06-deploy-monitoring.yml      # Grafana deployment
│   └── 07-validate-deployment.yml    # Validation checks
└── templates/
    └── clickhouse-s3-serviceaccount.yml.j2
```

## Prerequisites

1. **Ansible** installed (tested with Ansible 2.9+)

2. **Required tools** (validated by playbook):
   - terraform >= 1.6
   - kubectl
   - aws-cli
   - helm

3. **AWS credentials** configured:
   ```bash
   aws configure
   aws sts get-caller-identity
   ```

4. **Project structure** (update `inventory/eks.yml` if different):
   ```
   your-repo/
   ├── adsb-ansible/          # This directory
   ├── adsb-eks-terraform/    # Terraform config
   ├── manifests/
   │   └── clickhouse/        # K8s manifests
   ├── schema/                # SQL schema files
   ├── certs/                 # Kafka TLS certificates
   └── dashboards/            # Grafana dashboards (optional)
   ```

5. **TLS Certificates**
If you are hosting your own Kafka/Redpanda cluster, ensure that the required certs
and keys are created in the certs directory. See certs/README.md for details.
certs/ca.crt"
certs/client.crt"
certs/client.key"

6. **Users Schema File**
Copy schema/users.sql.example to users.sql, replacing the user passwords.


## Configuration

### Update Inventory

Copy `inventory/eks.yml.template` to `inventory/eks.yml`,
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
```

## Usage

### Full Deployment

Deploy everything (infrastructure + applications):

```bash
ansible-playbook -i inventory/eks.yml site.yml
```

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
