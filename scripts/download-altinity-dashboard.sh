#!/bin/bash
set -e

# Download the Altinity ClickHouse Operator Dashboard
DASHBOARD_URL="https://grafana.com/api/dashboards/12163/revisions/3/download"
OUTPUT_DIR="dashboards"
OUTPUT_FILE="$OUTPUT_DIR/altinity-clickhouse-operator-dashboard.json"

mkdir -p "$OUTPUT_DIR"

echo "Downloading Altinity ClickHouse Operator Dashboard..."
curl -s "$DASHBOARD_URL" -o "$OUTPUT_FILE"

if [ $? -eq 0 ]; then
    echo "Dashboard downloaded successfully"
    
    # Replace datasource variables with actual datasource names
    echo "Fixing datasource variables..."
    sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' "$OUTPUT_FILE"
    sed -i 's/\${DS_CLICKHOUSE}/ClickHouse/g' "$OUTPUT_FILE"
    
    # Also fix the __inputs section if it exists (Grafana import variables)
    # Remove the __inputs section entirely as we're provisioning, not importing
    sed -i '/"__inputs":/,/],/d' "$OUTPUT_FILE"
    
    echo "Dashboard fixed and ready at $OUTPUT_FILE"
    echo ""
    echo "To deploy, run:"
    echo "kubectl create configmap clickhouse-dashboards \\"
    echo "  --from-file=$OUTPUT_FILE \\"
    echo "  -n adsb-monitoring \\"
    echo "  --dry-run=client -o yaml | kubectl apply -f -"
    echo ""
    echo "Then restart Grafana to pick up the dashboard:"
    echo "kubectl rollout restart deployment grafana -n monitoring"
else
    echo "Failed to download dashboard"
    exit 1
fi
