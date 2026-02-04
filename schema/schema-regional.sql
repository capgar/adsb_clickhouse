-- ============================================================================
-- ADS-B ClickHouse Schema V3.3 - Multi-Shard with Distributed Tables
-- For Regional ADS-B API Data
-- 
-- Architecture for 2 shards × 2 replicas:
--   1. Kafka tables (consume on each pod independently)
--   2. Local ReplicatedMergeTree tables (data stored with replication)
--   3. Distributed tables (query across all shards)
--   4. Materialized views (Kafka → local storage)
--   5. Replacing tables (deduplicated current state per shard)
--   6. Latest batch views (most recent scrape)
--
-- Data Flow:
--   Kafka → MV → ReplicatedMergeTree (local) → Distributed (queries)
--                                            → ReplacingMergeTree → Latest views
-- ============================================================================

CREATE DATABASE IF NOT EXISTS adsb ON CLUSTER `adsb-data`;
USE adsb;

-- ============================================================================
-- KAFKA TABLES (Match scraper output exactly)
-- Each pod consumes independently - no sharding needed
-- ============================================================================

-- Regional Kafka (all fields from regional API)
CREATE TABLE IF NOT EXISTS positions_regional_kafka ON CLUSTER `adsb-data` (
    -- Core identification
    hex String,
    type String,
    flight String,
    r String,
    t String,
    desc String,
    -- Position data
    lat Nullable(Float64),
    lon Nullable(Float64),
    alt_baro String,
    alt_geom String,
    gs Nullable(Float32),
    track Nullable(Float32),
    baro_rate Nullable(Float32),
    -- Status
    squawk String,
    emergency String,
    category String,
    -- Navigation
    nav_qnh Nullable(Float32),
    nav_altitude_mcp Nullable(Int32),
    nav_modes Array(String),
    -- Quality indicators
    nic Nullable(Int32),
    rc Nullable(Int32),
    version Nullable(Int32),
    nic_baro Nullable(Int32),
    nac_p Nullable(Int32),
    nac_v Nullable(Int32),
    sil Nullable(Int32),
    sil_type String,
    gva Nullable(Int32),
    sda Nullable(Int32),
    -- Alerts
    alert Nullable(Int32),
    spi Nullable(Int32),
    -- Timing
    seen_pos Nullable(Float32),
    seen Nullable(Float32),
    -- Regional-specific
    rssi Nullable(Float32),
    messages Nullable(Int32),
    dst Nullable(Float32),
    dir Nullable(Float32),
    ownOp String,
    year String,
    -- Metadata
    source String,
    scrape_time DateTime
) ENGINE = Kafka(kafka_regional);


-- ============================================================================
-- LOCAL STORAGE TABLES (Replicated within each shard)
-- Data is sharded by icao24 hash across both shards
-- ============================================================================

-- Regional storage (90 days retention)
CREATE TABLE IF NOT EXISTS positions_regional ON CLUSTER `adsb-data` (
    -- Core identification
    icao24 String,
    type String,
    callsign String,
    registration String,
    aircraft_type String,
    description String,
    -- Position data
    lat Nullable(Float64),
    lon Nullable(Float64),
    alt_baro Nullable(Int32),
    alt_geom Nullable(Int32),
    ground_speed Nullable(Float32),
    track Nullable(Float32),
    vertical_rate Nullable(Float32),
    -- Status
    squawk String,
    emergency String,
    category String,
    -- Navigation
    nav_qnh Nullable(Float32),
    nav_altitude_mcp Nullable(Int32),
    nav_modes Array(String),
    -- Quality indicators
    nic Nullable(Int32),
    rc Nullable(Int32),
    version Nullable(Int32),
    nic_baro Nullable(Int32),
    nac_p Nullable(Int32),
    nac_v Nullable(Int32),
    sil Nullable(Int32),
    sil_type String,
    gva Nullable(Int32),
    sda Nullable(Int32),
    -- Alerts
    alert Nullable(Int32),
    spi Nullable(Int32),
    -- Timing
    seen_pos Nullable(Float32),
    seen Nullable(Float32),
    -- Regional-specific
    rssi Nullable(Float32),
    messages Nullable(Int32),
    distance Nullable(Float32),
    direction Nullable(Float32),
    owner_operator String,
    year String,
    -- Metadata
    scrape_time DateTime,
    ingestion_time DateTime
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/positions_regional', '{replica}')
PARTITION BY toYYYYMMDD(scrape_time)
ORDER BY (icao24, scrape_time)
TTL scrape_time + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS positions_regional_dist ON CLUSTER `adsb-data`
AS positions_regional
ENGINE = Distributed('adsb-data', adsb, positions_regional, rand());


-- ============================================================================
-- MATERIALIZED VIEWS: Kafka → Long-term Storage
-- These write to LOCAL tables, distributed table aggregates across shards
-- ============================================================================


CREATE MATERIALIZED VIEW IF NOT EXISTS positions_regional_kafka_mv ON CLUSTER `adsb-data` TO positions_regional AS
SELECT
    -- Core identification
    hex AS icao24,
    type,
    trim(flight) AS callsign,
    r AS registration,
    t AS aircraft_type,
    desc AS description,
    -- Position data
    lat,
    lon,
    CAST(
        CASE
            WHEN alt_baro = 'ground' THEN 0
            ELSE toInt32OrNull(alt_baro)
        END AS Nullable(Int32)
    ) AS alt_baro,
    toInt32OrNull(alt_geom) AS alt_geom,
    gs AS ground_speed,
    track,
    baro_rate AS vertical_rate,
    -- Status
    squawk,
    emergency,
    category,
    -- Navigation
    nav_qnh,
    nav_altitude_mcp,
    nav_modes,
    -- Quality indicators
    nic,
    rc,
    version,
    nic_baro,
    nac_p,
    nac_v,
    sil,
    sil_type,
    gva,
    sda,
    -- Alerts
    alert,
    spi,
    -- Timing
    seen_pos,
    seen,
    -- Regional-specific
    rssi,
    messages,
    dst AS distance,
    dir AS direction,
    ownOp AS owner_operator,
    year,
    -- Metadata
    scrape_time,
    now() AS ingestion_time
FROM positions_regional_kafka;


-- ============================================================================
-- REPLACING TABLES (Deduplicated current state per shard)
-- ============================================================================

CREATE TABLE IF NOT EXISTS positions_regional_replacing ON CLUSTER `adsb-data` (
    -- Core identification
    icao24 String,
    type String,
    callsign String,
    registration String,
    aircraft_type String,
    description String,
    -- Position data
    lat Nullable(Float64),
    lon Nullable(Float64),
    alt_baro Nullable(Int32),
    alt_geom Nullable(Int32),
    ground_speed Nullable(Float32),
    track Nullable(Float32),
    vertical_rate Nullable(Float32),
    -- Status
    squawk String,
    emergency String,
    category String,
    -- Navigation
    nav_qnh Nullable(Float32),
    nav_altitude_mcp Nullable(Int32),
    nav_modes Array(String),
    -- Quality indicators
    nic Nullable(Int32),
    rc Nullable(Int32),
    version Nullable(Int32),
    nic_baro Nullable(Int32),
    nac_p Nullable(Int32),
    nac_v Nullable(Int32),
    sil Nullable(Int32),
    sil_type String,
    gva Nullable(Int32),
    sda Nullable(Int32),
    -- Alerts
    alert Nullable(Int32),
    spi Nullable(Int32),
    -- Timing
    seen_pos Nullable(Float32),
    seen Nullable(Float32),
    -- Regional-specific
    rssi Nullable(Float32),
    messages Nullable(Int32),
    distance Nullable(Float32),
    direction Nullable(Float32),
    owner_operator String,
    year String,
    -- Timing metadata
    scrape_time DateTime,
    ingestion_time DateTime
) ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/positions_regional_replacing', '{replica}', scrape_time)
ORDER BY icao24
TTL scrape_time + INTERVAL 1 HOUR
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS positions_regional_replacing_dist ON CLUSTER `adsb-data`
AS positions_regional_replacing
ENGINE = Distributed('adsb-data', adsb, positions_regional_replacing, rand());


-- ============================================================================
-- MATERIALIZED VIEWS: Long-term Storage → Replacing Tables
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_regional_replacing_mv ON CLUSTER `adsb-data` TO positions_regional_replacing AS
SELECT
    icao24,
    type,
    callsign,
    registration,
    aircraft_type,
    description,
    lat,
    lon,
    alt_baro,
    alt_geom,
    ground_speed,
    track,
    vertical_rate,
    squawk,
    emergency,
    category,
    nav_qnh,
    nav_altitude_mcp,
    nav_modes,
    nic,
    rc,
    version,
    nic_baro,
    nac_p,
    nac_v,
    sil,
    sil_type,
    gva,
    sda,
    alert,
    spi,
    seen_pos,
    seen,
    rssi,
    messages,
    distance,
    direction,
    owner_operator,
    year,
    scrape_time,
    ingestion_time
FROM positions_regional
WHERE scrape_time > now() - INTERVAL 2 HOUR;


-- ============================================================================
-- LATEST BATCH VIEWS (Show only aircraft from most recent scrape)
-- Query from distributed replacing tables for complete view
-- ============================================================================

-- Regional latest batch (all aircraft from most recent scrape, all shards)
CREATE VIEW IF NOT EXISTS positions_regional_latest ON CLUSTER `adsb-data` AS
SELECT *
FROM positions_regional_replacing_dist FINAL
WHERE scrape_time > now() - INTERVAL 1 MINUTE
ORDER BY icao24, scrape_time DESC
LIMIT 1 BY icao24;


-- ============================================================================
-- USAGE NOTES
-- ============================================================================
-- 
-- For queries across all shards, use the *_dist tables:
--   SELECT count() FROM positions_local_dist;
--   SELECT * FROM positions_local_latest;  -- Views already use _dist tables
--
-- For queries on local shard only (rare), use the base tables:
--   SELECT count() FROM positions_local;
--
-- Data flow:
--   1. Kafka consumers (all pods) → Materialized View → Local ReplicatedMergeTree
--   2. Local tables are sharded by rand() across 2 shards
--   3. Each shard replicates to 2 replicas
--   4. Distributed tables aggregate queries across both shards
--   5. Replacing tables deduplicate by icao24 per shard
--   6. Latest views show most recent scrape from all shards
--
-- ============================================================================