-- ============================================================================
-- ADS-B ClickHouse Schema V4.0
-- For Local ADS-B Receiver Data
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

CREATE TABLE IF NOT EXISTS positions_local_kafka ON CLUSTER `adsb-data` (
    -- Core identification
    hex Nullable(String),
    type Nullable(String),
    flight Nullable(String),
    r Nullable(String),
    t Nullable(String),
    desc Nullable(String),
    ownOp Nullable(String),
    year Nullable(String),
    -- Position data
    lat Nullable(Float64),
    lon Nullable(Float64),
    alt_baro Nullable(String),
    alt_geom Nullable(Int32),
    gs Nullable(Float32),
    track Nullable(Float32),
    track_rate Nullable(Float32),
    roll Nullable(Float32),
    mag_heading Nullable(Float32),
    true_heading Nullable(Float32),
    baro_rate Nullable(Int32),
    geom_rate Nullable(Int32),
    -- Relative position
    r_dst Nullable(Float32),
    r_dir Nullable(Float32),
    -- Weather & Advanced Performance
    ias Nullable(Int32),
    tas Nullable(Int32),
    mach Nullable(Float32),
    oat Nullable(Int32),
    tat Nullable(Int32),
    ws Nullable(Int32),
    wd Nullable(Int32),
    -- Status
    squawk Nullable(String),
    emergency Nullable(String),
    category Nullable(String),
    alert Nullable(Bool),
    spi Nullable(Bool),
    -- Navigation
    nav_qnh Nullable(Float32),
    nav_altitude_mcp Nullable(Int32),
    nav_altitude_fms Nullable(Int32),
    nav_heading Nullable(Float32),
    nav_modes Array(String),
    -- Quality indicators
    version Nullable(Int32),
    nic Nullable(Int32),
    rc Nullable(Int32),
    nic_baro Nullable(Int32),
    nac_p Nullable(Int32),
    nac_v Nullable(Int32),
    sil Nullable(Int32),
    sil_type Nullable(String),
    gva Nullable(Int32),
    sda Nullable(Int32),
    dbFlags Nullable(Int32),
    -- Signal & Physical (Receiver)
    rssi Nullable(Float32),
    messages Nullable(Int32),
    mlat Array(String),
    tisb Array(String),
    -- State Persistence & Diagnosis (Receiver)
    seen_pos Nullable(Float32),
    seen Nullable(Float32),
    lastPosition Nullable(String),
    calc_track Nullable(Int32),
    gpsOkLat Nullable(Float64),
    gpsOkLon Nullable(Float64),
    gpsOkBefore Nullable(Float64),
    -- Metadata
    source LowCardinality(String),
    scrape_time DateTime
) ENGINE = Kafka(kafka_local);


-- ============================================================================
-- LOCAL STORAGE TABLES (Replicated within each shard)
-- Data is sharded by icao24 hash across both shards
-- ============================================================================

CREATE TABLE IF NOT EXISTS positions_local ON CLUSTER `adsb-data` (
    -- Core identification
    icao24 String,
    type LowCardinality(String),
    callsign String,
    registration String,
    aircraft_type LowCardinality(String),
    description String,
    owner_operator String,
    year String,
    -- Position data
    lat Float64,
    lon Float64,
    alt_baro Int32,
    alt_geom Int32,
    ground_speed Float32,
    track Float32,
    track_rate Float32,
    roll Float32,
    mag_heading Float32,
    true_heading Float32,
    vertical_rate Int32,
    geom_rate Int32,
    -- Relative position
    distance Float32,
    direction Float32,
    -- Weather & Advanced Performance
    ias Int32,
    tas Int32,
    mach Float32,
    oat Int32,
    tat Int32,
    wind_speed Int32,
    wind_direction Int32,
    -- Status
    squawk LowCardinality(String),
    emergency LowCardinality(String),
    category LowCardinality(String),
    alert Bool,
    spi Bool,
    -- Navigation
    nav_qnh Float32,
    nav_altitude_mcp Int32,
    nav_altitude_fms Int32,
    nav_heading Float32,
    nav_modes Array(LowCardinality(String)),
    -- Quality indicators
    version Int32,
    nic Int32,
    rc Int32,
    nic_baro Int32,
    nac_p Int32,
    nac_v Int32,
    sil Int32,
    sil_type LowCardinality(String),
    gva Int32,
    sda Int32,
    db_flags Int32,
    -- Signal & Physical (Receiver)
    rssi Float32,
    messages Int32,
    mlat Array(LowCardinality(String)),
    tisb Array(LowCardinality(String)),
    -- State Persistence & Diagnosis (Receiver)
    seen_pos Float32,
    seen Float32,
    last_position String,
    calc_track Int32,
    gps_ok_lat Float64,
    gps_ok_lon Float64,
    gps_ok_before Float64,
    -- Metadata
    source LowCardinality(String),
    scrape_time DateTime,
    ingestion_time DateTime
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/positions_local', '{replica}')
PARTITION BY toYYYYMMDD(scrape_time)
ORDER BY (icao24, scrape_time)
TTL scrape_time + INTERVAL 1 YEAR
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS positions_local_dist ON CLUSTER `adsb-data`
AS positions_local
ENGINE = Distributed('adsb-data', adsb, positions_local, rand());


-- ============================================================================
-- MATERIALIZED VIEWS: Kafka → Long-term Storage
-- These write to LOCAL tables, distributed table aggregates across shards
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_local_kafka_mv ON CLUSTER `adsb-data` TO positions_local AS
SELECT
    -- Core identification
    trimBoth(lower(ifNull(hex, ''))) AS icao24,
    ifNull(type, '') AS type,
    trimBoth(lower(ifNull(flight, ''))) AS callsign,
    ifNull(r, '') AS registration,
    ifNull(t, '') AS aircraft_type,
    ifNull(desc, '') AS description,
    ifNull(ownOp, '') AS owner_operator,
    ifNull(year, '') AS year,
    -- Position data
    lat,
    lon,
    CASE
        WHEN alt_baro = 'ground' THEN toInt32(0)
        WHEN alt_baro IS NULL THEN toInt32(-9999)
        ELSE toInt32(alt_baro)
    END AS alt_baro,
    toInt32(ifNull(alt_geom, toInt32(-9999))) AS alt_geom,
    toFloat32(ifNull(gs, toFloat32(-9999))) AS ground_speed,
    toFloat32(ifNull(track, toFloat32(-9999))) AS track,
    toFloat32(ifNull(track_rate, toFloat32(-9999))) AS track_rate,
    toFloat32(ifNull(roll, toFloat32(-9999))) AS roll,
    toFloat32(ifNull(mag_heading, toFloat32(-9999))) AS mag_heading,
    toFloat32(ifNull(true_heading, toFloat32(-9999))) AS true_heading,
    toInt32(ifNull(baro_rate, toInt32(-9999))) AS vertical_rate,
    toInt32(ifNull(geom_rate, toInt32(-9999))) AS geom_rate,
    -- Relative position
    toFloat32(ifNull(r_dst, toFloat32(-9999))) AS distance,
    toFloat32(ifNull(r_dir, toFloat32(-9999))) AS direction,
    -- Weather & Advanced Performance
    toInt32(ifNull(ias, toInt32(-9999))) AS ias,
    toInt32(ifNull(tas, toInt32(-9999))) AS tas,
    toFloat32(ifNull(mach, toFloat32(-9999))) AS mach,
    toInt32(ifNull(oat, toInt32(-9999))) AS oat,
    toInt32(ifNull(tat, toInt32(-9999))) AS tat,
    toInt32(ifNull(ws, toInt32(-9999))) AS wind_speed,
    toInt32(ifNull(wd, toInt32(-9999))) AS wind_direction,
    -- Status
    ifNull(squawk, '') AS squawk,
    ifNull(emergency, '') AS emergency,
    ifNull(category, '') AS category,
    ifNull(alert, false) AS alert,
    ifNull(spi, false) AS spi,
    -- Navigation
    toFloat32(ifNull(nav_qnh, toFloat32(-9999))) AS nav_qnh,
    toInt32(ifNull(nav_altitude_mcp, toInt32(-9999))) AS nav_altitude_mcp,
    toInt32(ifNull(nav_altitude_fms, toInt32(-9999))) AS nav_altitude_fms,
    toFloat32(ifNull(nav_heading, toFloat32(-9999))) AS nav_heading,
    arrayFilter(
        x -> x != '', 
        arrayMap(x -> trimBoth(lower(x)), nav_modes)
    ) AS nav_modes,
    -- Quality indicators
    toInt32(ifNull(version, toInt32(-9999))) AS version,
    toInt32(ifNull(nic, toInt32(-9999))) AS nic,
    toInt32(ifNull(rc, toInt32(-9999))) AS rc,
    toInt32(ifNull(nic_baro, toInt32(-9999))) AS nic_baro,
    toInt32(ifNull(nac_p, toInt32(-9999))) AS nac_p,
    toInt32(ifNull(nac_v, toInt32(-9999))) AS nac_v,
    toInt32(ifNull(sil, toInt32(-9999))) AS sil,
    ifNull(sil_type, '') AS sil_type,
    toInt32(ifNull(gva, toInt32(-9999))) AS gva,
    toInt32(ifNull(sda, toInt32(-9999))) AS sda,
    toInt32(ifNull(dbFlags, toInt32(-9999))) AS db_flags,
    -- Signal & Physical (Receiver)
    toFloat32(ifNull(rssi, toFloat32(-9999))) AS rssi,
    toInt32(ifNull(messages, toInt32(-9999))) AS messages,
    arrayFilter(
        x -> x != '', 
        arrayMap(x -> trimBoth(lower(x)), mlat)
    ) AS mlat,
    arrayFilter(
        x -> x != '', 
        arrayMap(x -> trimBoth(lower(x)), tisb)
    ) AS tisb,
    -- State Persistence & Diagnosis (Receiver)
    toFloat32(ifNull(seen_pos, toFloat32(0.0))) AS seen_pos,
    toFloat32(ifNull(seen, toFloat32(0.0))) AS seen,
    ifNull(lastPosition, '') AS last_position,
    toInt32(ifNull(calc_track, toInt32(-9999))) AS calc_track,
    toFloat64(ifNull(gpsOkLat, toFloat64(-9999))) AS gps_ok_lat,
    toFloat64(ifNull(gpsOkLon, toFloat64(-9999))) AS gps_ok_lon,
    toFloat64(ifNull(gpsOkBefore, toFloat64(-9999))) AS gps_ok_before,
    -- Metadata
    source,
    scrape_time,
    now() AS ingestion_time
FROM positions_local_kafka
WHERE isNotNull(hex)
AND isNotNull(lat)
AND isNotNull(lon)
AND lat BETWEEN -90 AND 90
AND lon BETWEEN -180 AND 180;


-- ============================================================================
-- REPLACING TABLES (Deduplicated current state per shard)
-- ============================================================================

CREATE TABLE IF NOT EXISTS positions_local_replacing ON CLUSTER `adsb-data` (
    -- Core identification
    icao24 String,
    type LowCardinality(String),
    callsign String,
    registration String,
    aircraft_type LowCardinality(String),
    description String,
    owner_operator String,
    year String,
    -- Position data
    lat Float64,
    lon Float64,
    alt_baro Int32,
    alt_geom Int32,
    ground_speed Float32,
    track Float32,
    track_rate Float32,
    roll Float32,
    mag_heading Float32,
    true_heading Float32,
    vertical_rate Int32,
    geom_rate Int32,
    -- Relative position
    distance Float32,
    direction Float32,
    -- Weather & Advanced Performance
    ias Int32,
    tas Int32,
    mach Float32,
    oat Int32,
    tat Int32,
    wind_speed Int32,
    wind_direction Int32,
    -- Status
    squawk LowCardinality(String),
    emergency LowCardinality(String),
    category LowCardinality(String),
    alert Bool,
    spi Bool,
    -- Navigation
    nav_qnh Float32,
    nav_altitude_mcp Int32,
    nav_altitude_fms Int32,
    nav_heading Float32,
    nav_modes Array(LowCardinality(String)),
    -- Quality indicators
    version Int32,
    nic Int32,
    rc Int32,
    nic_baro Int32,
    nac_p Int32,
    nac_v Int32,
    sil Int32,
    sil_type LowCardinality(String),
    gva Int32,
    sda Int32,
    db_flags Int32,
    -- Signal & Physical (Receiver)
    rssi Float32,
    messages Int32,
    mlat Array(LowCardinality(String)),
    tisb Array(LowCardinality(String)),
    -- Timing
    seen_pos Float32,
    seen Float32,
    -- Timing metadata
    source LowCardinality(String),
    scrape_time DateTime,
    ingestion_time DateTime
) ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/positions_local_replacing', '{replica}', scrape_time)
ORDER BY icao24
TTL scrape_time + INTERVAL 1 HOUR;


CREATE TABLE IF NOT EXISTS positions_local_replacing_dist ON CLUSTER `adsb-data`
AS positions_local_replacing
ENGINE = Distributed('adsb-data', adsb, positions_local_replacing, rand());


-- ============================================================================
-- MATERIALIZED VIEWS: Long-term Storage → Replacing Tables
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_local_replacing_mv ON CLUSTER `adsb-data` TO positions_local_replacing AS
SELECT
    icao24,
    type,
    callsign,
    registration,
    aircraft_type,
    description,
    owner_operator,
    year,
    lat,
    lon,
    alt_baro,
    alt_geom,
    ground_speed,
    track,
    track_rate,
    roll,
    mag_heading,
    true_heading,
    vertical_rate,
    geom_rate,
    distance,
    direction,
    ias,
    tas,
    mach,
    oat,
    tat,
    wind_speed,
    wind_direction,
    squawk,
    emergency,
    category,
    alert,
    spi,
    nav_qnh,
    nav_altitude_mcp,
    nav_altitude_fms,
    nav_heading,
    nav_modes,
    version,
    nic,
    rc,
    nic_baro,
    nac_p,
    nac_v,
    sil,
    sil_type,
    gva,
    sda,
    db_flags,
    rssi,
    messages,
    mlat,
    tisb,
    seen_pos,
    seen,
    source,
    scrape_time,
    ingestion_time
FROM positions_local
WHERE scrape_time > now() - INTERVAL 2 HOUR;


-- ============================================================================
-- LATEST BATCH VIEWS (Show only aircraft from most recent scrape)
-- Query from distributed replacing tables for complete view
-- ============================================================================

-- Local latest batch (all aircraft from most recent scrape, all shards)
CREATE VIEW IF NOT EXISTS positions_local_latest ON CLUSTER `adsb-data` AS
SELECT *
FROM positions_local_replacing_dist FINAL
WHERE scrape_time > now() - INTERVAL 15 SECOND
ORDER BY icao24, scrape_time DESC
LIMIT 1 BY icao24;