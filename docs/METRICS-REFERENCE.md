# ClickHouse Metrics Reference Guide

This guide lists the most useful metrics you can query in Prometheus and visualize in Grafana for your ADS-B data pipeline.

## ClickHouse Operator Metrics

These come from the ClickHouse Operator (ports 8888, 9999):

### Cluster Health
```promql
# Number of ClickHouse installations
clickhouse_operator_chi_count

# Number of pods managed
clickhouse_operator_pod_count

# Failed reconciliations
clickhouse_operator_chi_reconciles_failed_total
```

## ClickHouse Server Metrics

These come from your ClickHouse cluster (port 9363):

### Query Performance
```promql
# Active queries
clickhouse_Query

# Query execution time
clickhouse_QueryTimeMicroseconds

# Failed queries
clickhouse_FailedQuery

# Delayed inserts
clickhouse_DelayedInserts
```

### Table and Data Metrics
```promql
# Total number of parts (important for MergeTree health)
clickhouse_PartsActive
clickhouse_PartsTemporary
clickhouse_PartsPreActive

# Background merges
clickhouse_BackgroundMergesAndMutationsPoolTask
clickhouse_Merge

# Read/Write operations
clickhouse_DiskReadElapsedMicroseconds
clickhouse_DiskWriteElapsedMicroseconds
```

### Memory and Resources
```promql
# Memory usage
clickhouse_MemoryTracking
clickhouse_MemoryTrackingInBackgroundProcessingPool

# Network
clickhouse_NetworkReceiveBytes
clickhouse_NetworkSendBytes

# Open file descriptors
clickhouse_OpenFileForRead
clickhouse_OpenFileForWrite
```

### Kafka Consumer Metrics (for your ADS-B pipeline)
```promql
# Kafka consumer lag
clickhouse_KafkaConsumerLag

# Kafka assignments
clickhouse_KafkaAssignedPartitions

# Kafka consumer messages
clickhouse_KafkaConsumerMessages
```

### Replication (when you add replicas)
```promql
# Replication lag
clickhouse_ReplicatedPartMutations
clickhouse_ReplicatedPartFetches

# Replication queue
clickhouse_ReplicatedPartCheckActions
```

## ClickHouse Keeper Metrics

These come from Keeper (port 9234, if enabled):

### Keeper Health
```promql
# Keeper state (1=leader, 0=follower)
clickhouse_keeper_is_leader

# Active connections
clickhouse_keeper_alive_connections

# Outstanding requests
clickhouse_keeper_outstanding_requests
```

### Keeper Performance
```promql
# Average latency
clickhouse_keeper_avg_latency_ms

# Min/Max latency
clickhouse_keeper_min_latency_ms
clickhouse_keeper_max_latency_ms

# Packets sent/received
clickhouse_keeper_packets_sent
clickhouse_keeper_packets_received
```

### Keeper Data
```promql
# Approximate data size
clickhouse_keeper_approximate_data_size

# Ephemeral nodes
clickhouse_keeper_ephemerals_count

# Watch count
clickhouse_keeper_watch_count

# ZNodes count
clickhouse_keeper_znode_count
```

## Useful Dashboard Queries for Your ADS-B Pipeline

### Kafka Ingestion Rate
```promql
# Messages per second from Kafka
rate(clickhouse_KafkaConsumerMessages[1m])

# By topic (requires labels)
sum(rate(clickhouse_KafkaConsumerMessages{topic="flights-local"}[1m]))
sum(rate(clickhouse_KafkaConsumerMessages{topic="flights-regional"}[1m]))
sum(rate(clickhouse_KafkaConsumerMessages{topic="flights-global"}[1m]))
```

### Insert Performance
```promql
# Inserts per second
rate(clickhouse_InsertedRows[1m])

# Bytes inserted per second
rate(clickhouse_InsertedBytes[1m])
```

### Query Load
```promql
# Queries per second
rate(clickhouse_Query[1m])

# Average query duration
rate(clickhouse_QueryTimeMicroseconds[5m]) / rate(clickhouse_Query[5m]) / 1000000

# Slow queries (>1s)
clickhouse_QueryTimeMicroseconds > 1000000
```

### Table Size and Health
```promql
# Active parts per table
clickhouse_PartsActive{database="adsb"}

# Merge rate
rate(clickhouse_Merge[5m])

# Parts that need merging
clickhouse_PartsOutdated
```

### Memory Pressure
```promql
# Total memory used
clickhouse_MemoryTracking

# Memory used by background tasks
clickhouse_MemoryTrackingInBackgroundProcessingPool

# Memory usage percentage (if you set max_memory_usage=4GB)
(clickhouse_MemoryTracking / 4000000000) * 100
```

### Disk I/O
```promql
# Disk read rate (bytes/sec)
rate(clickhouse_DiskReadElapsedMicroseconds[1m])

# Disk write rate (bytes/sec)
rate(clickhouse_DiskWriteElapsedMicroseconds[1m])
```

## Alerting Suggestions

Consider setting up alerts for:

```promql
# High query latency
avg(rate(clickhouse_QueryTimeMicroseconds[5m])) > 500000  # >500ms

# Too many active parts (indicates merge issues)
clickhouse_PartsActive > 1000

# High memory usage
clickhouse_MemoryTracking > 3500000000  # >3.5GB (87.5% of 4GB limit)

# Kafka consumer lag
clickhouse_KafkaConsumerLag > 10000

# Failed queries
rate(clickhouse_FailedQuery[5m]) > 1

# Keeper not leader (if you later add replicas)
clickhouse_keeper_is_leader == 0

# No active ClickHouse installations
clickhouse_operator_chi_count < 1
```

## Grafana Panel Examples

### Single Stat Panels
- Current Kafka messages/sec: `sum(rate(clickhouse_KafkaConsumerMessages[1m]))`
- Active queries: `clickhouse_Query`
- Memory usage %: `(clickhouse_MemoryTracking / 4000000000) * 100`
- Active table parts: `sum(clickhouse_PartsActive)`

### Time Series Graphs
- Insert rate over time: `rate(clickhouse_InsertedRows[1m])`
- Query duration: `rate(clickhouse_QueryTimeMicroseconds[5m]) / rate(clickhouse_Query[5m]) / 1000000`
- Kafka ingestion by topic: `sum by (topic) (rate(clickhouse_KafkaConsumerMessages[1m]))`

### Table Panels
- Recent slow queries: Query ClickHouse `system.query_log` table directly via ClickHouse datasource
- Current Kafka consumer lag by partition
- Active merges and mutations

## Notes

- The exact metric names may vary slightly depending on your ClickHouse version
- Some metrics require specific features to be enabled in ClickHouse configuration
- Keeper metrics are only available if you've enabled Prometheus metrics in your ClickHouseKeeperInstallation
- Use `prometheus.asynchronous_metrics: true` to get additional system metrics (CPU, disk, etc.)

