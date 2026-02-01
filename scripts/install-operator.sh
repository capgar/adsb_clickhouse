#!/bin/bash

NAMESPACE="adsb-clickhouse"
OPERATOR_VERSION="0.25.6"  # Or "latest" - check https://github.com/Altinity/clickhouse-operator/releases
MANIFEST_URL="https://raw.githubusercontent.com/Altinity/clickhouse-operator/${OPERATOR_VERSION}/deploy/operator/clickhouse-operator-install-bundle.yaml"

echo "Downloading ClickHouse operator manifest..."
curl -sL "$MANIFEST_URL" | \

# Add namespace to all resources
sed "s/namespace: kube-system/namespace: ${NAMESPACE}/g" | \

# Add WATCH_NAMESPACE env var (insert after the 'env:' line in the Deployment)
sed '/name: clickhouse-operator$/,/env:/{
  /env:/a\
        - name: WATCH_NAMESPACE\
          value: "'"${NAMESPACE}"'"\
        - name: OPERATOR_INSTALL_VALIDATING_WEBHOOK\
          value: "false"\
        - name: OPERATOR_INSTALL_MUTATING_WEBHOOK\
          value: "false"
}' | \

# Apply to cluster
kubectl apply -f -

echo "Operator installed in ${NAMESPACE} namespace"
