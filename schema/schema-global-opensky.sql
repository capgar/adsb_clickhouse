-- ============================================================================
-- ClickHouse Schema for OpenSky Network Data
-- ============================================================================
-- OpenSky uses metrics units while other sources use imperial
-- - Altitude: meters (OpenSky) vs feet (others)
-- - Speed: m/s (OpenSky) vs knots (others)
-- - Vertical rate: m/s (OpenSky) vs feet/min (others)
-- 
-- For consistency, this schema converts to imperial in the MV
-- If desired, the other schemas could instead convert imperial -> metric
-- ============================================================================

CREATE DATABASE IF NOT EXISTS adsb ON CLUSTER `adsb-data`;
USE adsb;

-- ============================================================================
-- KAFKA TABLE for OpenSky
-- Matches scraper output exactly (metric units, opensky naming and types)
-- ============================================================================

CREATE TABLE IF NOT EXISTS positions_global_opensky_kafka ON CLUSTER `adsb-data` (
    -- Identification
    icao24 Nullable(String),
    callsign Nullable(String),
    -- Position & Movement
    lat Nullable(Float64),
    lon Nullable(Float64),
    baro_altitude Nullable(Float32),
    geo_altitude Nullable(Float32),
    velocity Nullable(Float32),
    true_track Nullable(Float32),
    vertical_rate Nullable(Float32),
    -- Status
    squawk Nullable(String),
    spi Nullable(Int32),
    -- Opensky specific
    origin_country Nullable(String),
    time_position Nullable(Int32),
    last_contact Nullable(Int32),
    on_ground Nullable(Bool),
    sensors Array(Int32),
    position_source Nullable(Int32),
    -- Scraper metadata
    source LowCardinality(String),
    scrape_time DateTime
) ENGINE = Kafka(kafka_global_opensky);


-- ============================================================================
-- STORAGE TABLES
-- ============================================================================

CREATE TABLE IF NOT EXISTS positions_global_opensky ON CLUSTER `adsb-data` (
    -- Identification
    icao24 String,
    callsign String,
    -- Position & Movement
    lat Float64,
    lon Float64,
    alt_baro Int32,
    alt_geom Int32,
    on_ground Bool,
    ground_speed Float32,
    track Float32,
    vertical_rate Float32,
    -- Status
    squawk LowCardinality(String),
    spi Bool,
    -- Opensky specific
    origin_country LowCardinality(String),
    time_position DateTime,
    last_contact DateTime,
    sensors Array(Int32),
    position_source Enum8(
        'ADS-B' = 0,
        'ASTERIX' = 1,
        'MLAT' = 2,
        'FLARM' = 3
    ),
    -- Scraper metadata
    source LowCardinality(String),
    scrape_time DateTime,
    ingestion_time DateTime
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/positions_global_opensky', '{replica}')
PARTITION BY toYYYYMMDD(scrape_time)
ORDER BY (icao24, scrape_time)
TTL scrape_time + INTERVAL 30 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS positions_global_opensky_dist ON CLUSTER `adsb-data`
AS positions_global_opensky
ENGINE = Distributed('adsb-data', adsb, positions_global_opensky, rand());


-- ============================================================================
-- MATERIALIZED VIEW: Kafka → Long-term Storage
-- CONVERTS METRIC TO IMPERIAL UNITS
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_global_opensky_kafka_mv ON CLUSTER `adsb-data` TO positions_global_opensky AS
SELECT
    trimBoth(lower(ifNull(icao24, ''))) AS icao24,
    trimBoth(upper(ifNull(callsign, ''))) AS callsign,
    lat,
    lon,
    -- ALTITUDE CONVERSION: meters → feet (multiply by 3.28084)
    ifNull(on_ground, false) AS on_ground,
    CASE
        WHEN baro_altitude IS NULL AND on_ground THEN toInt32(0)
        WHEN baro_altitude IS NULL THEN toInt32(-9999)
        ELSE toInt32(baro_altitude * 3.28084)
    END AS alt_baro,
    toInt32(ifNull(toInt32(geo_altitude * 3.28084), toInt32(-9999))) AS alt_geom,
    -- SPEED CONVERSION: m/s → knots (multiply by 1.94384)
    toFloat32(ifNull(velocity * toFloat32(1.94384), toFloat32(-9999))) AS ground_speed,
    toFloat32(ifNull(true_track, toFloat32(-9999))) AS track,
    -- VERTICAL RATE CONVERSION: m/s → feet/min (multiply by 196.85)
    toFloat32(ifNull(vertical_rate * toFloat32(196.85), toFloat32(-9999))) AS vertical_rate,
    ifNull(squawk, '') AS squawk,
    ifNull(spi = 1, false) AS spi,
    ifNull(origin_country, '') AS origin_country,
    fromUnixTimestamp(ifNull(time_position, toInt32(0))) AS time_position,
    fromUnixTimestamp(ifNull(last_contact, toInt32(0))) AS last_contact,
    sensors,
    CAST(
        ifNull(position_source, toInt32(0)) AS Enum8(
            'ADS-B' = 0,
            'ASTERIX' = 1,
            'MLAT' = 2,
            'FLARM' = 3
        )
    ) AS position_source,
    source,
    scrape_time,
    now() AS ingestion_time
FROM positions_global_opensky_kafka
WHERE isNotNull(icao24)
AND isNotNull(lat)
AND isNotNull(lon)
AND lat BETWEEN -90 AND 90
AND lon BETWEEN -180 AND 180;


-- ============================================================================
-- REPLACING TABLE (Deduplicated current state)
-- ============================================================================

CREATE TABLE IF NOT EXISTS positions_global_opensky_replacing ON CLUSTER `adsb-data` (
    -- Identification
    icao24 String,
    callsign String,
    -- Position & Movement
    lat Float64,
    lon Float64,
    alt_baro Int32,
    alt_geom Int32,
    ground_speed Float32,
    track Float32,
    vertical_rate Float32,
    -- Status
    squawk LowCardinality(String),
    spi Bool,
    -- Opensky specific
    origin_country LowCardinality(String),
    time_position DateTime,
    last_contact DateTime,
    sensors Array(Int32),
    position_source Enum8(
        'ADS-B' = 0,
        'ASTERIX' = 1,
        'MLAT' = 2,
        'FLARM' = 3
    ),
    -- Scraper metadata
    source LowCardinality(String),
    scrape_time DateTime,
    ingestion_time DateTime
) ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/positions_global_opensky_replacing', '{replica}', scrape_time)
ORDER BY icao24
TTL scrape_time + INTERVAL 1 HOUR;

CREATE TABLE IF NOT EXISTS positions_global_opensky_replacing_dist ON CLUSTER `adsb-data`
AS positions_global_opensky_replacing
ENGINE = Distributed('adsb-data', adsb, positions_global_opensky_replacing, rand());


-- ============================================================================
-- MATERIALIZED VIEWS: Long-term Storage → Replacing Tables
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_global_opensky_replacing_mv ON CLUSTER `adsb-data` TO positions_global_opensky_replacing AS
SELECT
    icao24,
    callsign,
    lat,
    lon,
    alt_baro,
    alt_geom,
    ground_speed,
    track,
    vertical_rate,
    squawk,
    spi,
    origin_country,
    time_position,
    last_contact,
    sensors,
    position_source,
    source,
    scrape_time,
    ingestion_time
FROM positions_global_opensky
WHERE scrape_time > now() - INTERVAL 2 HOUR;


-- ============================================================================
-- LATEST BATCH VIEWS (Show only aircraft from most recent scrape)
-- Query from distributed replacing tables for complete view
-- ============================================================================

-- Opensky latest batch (all aircraft from most recent scrape, all shards)
CREATE VIEW IF NOT EXISTS positions_global_opensky_latest ON CLUSTER `adsb-data` AS
SELECT *
FROM positions_global_opensky_replacing_dist FINAL
WHERE scrape_time > now() - INTERVAL 5 MINUTE
ORDER BY icao24, scrape_time DESC
LIMIT 1 BY icao24;