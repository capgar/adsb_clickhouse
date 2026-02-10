-- ============================================================================
-- ClickHouse Schema - Global Combined
-- ============================================================================
-- Adds another MV -> Replacing table to combine the Global Stream + Opensky data
-- ============================================================================

USE adsb;

-- ============================================================================
-- REPLACING TABLE (Deduplicated current state)
-- ============================================================================

CREATE TABLE IF NOT EXISTS positions_global_combined_test ON CLUSTER `adsb-data` (
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
    -- Scraper metadata
    source LowCardinality(String),
    scrape_time DateTime,
    ingestion_time DateTime
) ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/positions_global_combined_test', '{replica}', scrape_time)
ORDER BY icao24
TTL scrape_time + INTERVAL 1 HOUR;

CREATE TABLE IF NOT EXISTS positions_global_combined_test_dist ON CLUSTER `adsb-data`
AS positions_global_opensky_replacing
ENGINE = Distributed('adsb-data', adsb, positions_global_combined_test, rand());


-- ============================================================================
-- MATERIALIZED VIEWS: Long-term Storage → Replacing Tables
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_local_to_combined_mv ON CLUSTER `adsb-data` TO positions_global_combined_test AS
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
    source,
    scrape_time,
    ingestion_time
FROM positions_local
WHERE scrape_time > now() - INTERVAL 2 HOUR;

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_regional_to_combined_mv ON CLUSTER `adsb-data` TO positions_global_combined_test AS
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
    source,
    scrape_time,
    ingestion_time
FROM positions_regional
WHERE scrape_time > now() - INTERVAL 2 HOUR;

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_global_stream_to_combined_mv ON CLUSTER `adsb-data` TO positions_global_combined_test AS
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
    source,
    scrape_time,
    ingestion_time
FROM positions_global_stream
WHERE scrape_time > now() - INTERVAL 2 HOUR;

CREATE MATERIALIZED VIEW IF NOT EXISTS positions_global_opensky_to_combined_mv ON CLUSTER `adsb-data` TO positions_global_combined_test AS
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
CREATE VIEW IF NOT EXISTS positions_global_combined_latest ON CLUSTER `adsb-data` AS
SELECT *
FROM positions_global_combined_test_dist FINAL
WHERE scrape_time > now() - INTERVAL 5 MINUTE
ORDER BY icao24, scrape_time DESC
LIMIT 1 BY icao24;