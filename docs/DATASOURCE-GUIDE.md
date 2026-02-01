# Grafana Datasource Usage Guide

This guide explains when to use each datasource for monitoring your ClickHouse ADS-B pipeline.

## Available Datasources

### 1. ClickHouse (vertamedia-clickhouse-datasource)
**Primary datasource for the Altinity dashboard and ClickHouse system metrics**

**Use this for:**
- Altinity ClickHouse Operator dashboard (ID 12163)
- Querying ClickHouse system tables:
  - `system.parts` - Table parts, sizes, rows
  - `system.query_log` - Query performance history
  - `system.merges` - Merge operations
  - `system.mutations` - Table mutations
  - `system.replication_queue` - Replication status
  - `system.metrics` - Current metric values
  - `system.asynchronous_metrics` - Asynchronous metrics
  - `system.events` - Event counters
- Custom dashboards that need rich SQL queries
- Analyzing historical query performance
- Monitoring specific table metrics

**Example queries:**
```sql
-- Table sizes
SELECT 
    database,
    table,
    formatReadableSize(sum(bytes)) AS size,
    sum(rows) AS rows
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY sum(bytes) DESC

-- Recent slow queries
SELECT 
    query_duration_ms,
    query,
    user,
    read_rows,
    formatReadableSize(read_bytes) AS read_size
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
ORDER BY event_time DESC
LIMIT 20

-- Active Kafka consumers
SELECT 
    database,
    table,
    assignments.topic,
    assignments.partition_id,
    assignments.current_offset,
    assignments.high_water_mark,
    assignments.high_water_mark - assignments.current_offset AS lag
FROM system.kafka_consumers
ARRAY JOIN assignments
```

**Connection details:**
- Type: `vertamedia-clickhouse-datasource`
- URL: `http://chi-adsb-data-adsb-data-0-0.clickhouse.svc.cluster.local:8123`
- Database: `default` (or specify your database)
- Auth: Username/password via secrets

### 2. ClickHouse-Official (grafana-clickhouse-datasource)
**Alternative/secondary ClickHouse datasource**

**Use this for:**
- If you prefer the official Grafana plugin
- When the vertamedia plugin has issues or limitations
- Testing/comparing query results between plugins

**Note:** The Altinity dashboard was designed for vertamedia, so stick with that for the operator dashboard. You can enable this datasource if you want to build custom dashboards with the official plugin.

**Connection details:**
- Type: `grafana-clickhouse-datasource`
- URL: Same as vertamedia
- Currently commented out in config

### 3. Prometheus
**Real-time metrics and operator health monitoring**

**Use this for:**
- ClickHouse Operator metrics (from ports 8888, 9999):
  - `clickhouse_operator_chi_count` - Number of managed CHIs
  - `clickhouse_operator_pod_count` - Managed pods
  - `clickhouse_operator_chi_reconciles_*` - Reconciliation metrics
  
- Real-time ClickHouse server metrics (from port 9363):
  - `clickhouse_Query` - Active queries
  - `clickhouse_MemoryTracking` - Current memory usage
  - `clickhouse_PartsActive` - Active table parts
  - `clickhouse_Merge` - Active merges
  - `clickhouse_KafkaConsumerMessages` - Kafka consumption rate
  
- ClickHouse Keeper metrics (from port 9234):
  - `clickhouse_keeper_is_leader` - Leader status
  - `clickhouse_keeper_alive_connections` - Active connections
  - `clickhouse_keeper_avg_latency_ms` - Average latency

**Example queries:**
```promql
# Kafka messages per second
rate(clickhouse_KafkaConsumerMessages[1m])

# Memory usage percentage
(clickhouse_MemoryTracking / 4000000000) * 100

# Query rate
rate(clickhouse_Query[5m])

# Active table parts
sum(clickhouse_PartsActive) by (database, table)
```

**Connection details:**
- Type: `prometheus`
- URL: `http://prometheus.monitoring.svc.cluster.local:9090`
- Set as default datasource

## When to Use Which Datasource

### For Monitoring Dashboards

**Use ClickHouse (vertamedia) when you need:**
- Historical data analysis (query logs, past metrics)
- Detailed table statistics (parts, sizes, compression)
- Complex SQL aggregations
- Data that's already in ClickHouse system tables
- The Altinity operator dashboard

**Use Prometheus when you need:**
- Real-time metrics (current state)
- Sub-minute resolution time series
- Alerting rules
- Operator health monitoring
- Quick metric aggregation across time ranges
- Standard monitoring patterns (rate, increase, avg_over_time)

### For Your ADS-B Pipeline

**ClickHouse datasource - Use for:**
1. **Table health monitoring:**
   - Parts per table
   - Table sizes and growth
   - Merge activity

2. **Query performance analysis:**
   - Slow query identification
   - Query patterns over time
   - Resource usage per query

3. **Data ingestion tracking:**
   - Kafka consumer lag (from `system.kafka_consumers`)
   - Insert performance (from `system.query_log`)
   - Data freshness

4. **Business metrics:**
   - Flight counts by region
   - Data coverage over time
   - Aircraft tracking statistics

**Prometheus datasource - Use for:**
1. **Real-time health:**
   - Current Kafka ingestion rate
   - Active queries right now
   - Current memory usage
   - Parts accumulation rate

2. **Operational alerting:**
   - High query latency
   - Memory pressure
   - Too many parts
   - Kafka consumer lag

3. **Operator monitoring:**
   - CHI reconciliation failures
   - Operator pod health
   - Keeper leader status

## Combining Both Datasources

The most powerful dashboards use **both datasources**:

**Example dashboard structure:**
- **Top row (Prometheus):** Real-time KPIs
  - Current messages/sec
  - Active queries
  - Memory usage %
  
- **Middle rows (ClickHouse):** Historical analysis
  - Query performance over 24h
  - Table growth trends
  - Slowest queries table

- **Bottom rows (Mixed):**
  - Prometheus: Alert status, recent spikes
  - ClickHouse: Detailed drill-down queries

## Configuration Notes

### Using Environment Variables
The datasources reference `${CLICKHOUSE_PASSWORD}` which is expanded from environment variables. Make sure to set this in your Grafana deployment:

```yaml
env:
- name: GF_PROVISIONING_DATASOURCES_EXPAND_ENV
  value: "true"
- name: CLICKHOUSE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: grafana-secrets
      key: clickhouse-password
```

### Testing Datasources
After deployment, verify both datasources work:

1. **ClickHouse (vertamedia):**
   - Go to Explore
   - Select "ClickHouse" datasource
   - Run: `SELECT version()`
   - Should return ClickHouse version

2. **Prometheus:**
   - Go to Explore
   - Select "Prometheus" datasource
   - Run: `up`
   - Should show scrape targets

## Summary

| Feature | ClickHouse (vertamedia) | Prometheus |
|---------|------------------------|------------|
| **Primary Use** | System table queries | Real-time metrics |
| **Query Language** | SQL | PromQL |
| **Data Retention** | As long as in ClickHouse | 30 days (configurable) |
| **Resolution** | Depends on table | 30 second scrape interval |
| **Best For** | Historical analysis | Current state & alerting |
| **Altinity Dashboard** | ✓ Primary | ✓ Supplementary |
| **Custom Dashboards** | ✓ Rich SQL queries | ✓ Time series |
| **Alerting** | Limited | ✓ Excellent |

**Bottom line:** Use vertamedia-clickhouse for the Altinity dashboard and deep ClickHouse analysis, use Prometheus for real-time monitoring and alerting. Both are valuable and complementary!

