#!/usr/bin/env python3
"""
------------------------------------------------------------------------------------
ADS-B Aircraft Data Scraper with Kafka Integration
Polls multiple sources (local + public) for current aircraft position data
Publishes aircraft data to Kafka topics for consumption by ClickHouse
------------------------------------------------------------------------------------
NOTE: polling public feeds may require that you are an ADS-B data feeder yourself
------------------------------------------------------------------------------------
"""

import os
import sys
import time
import logging
import json
import requests
from datetime import datetime, timezone
from typing import List, Dict, Any
from kafka import KafkaProducer
from kafka.errors import KafkaError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class ConfigManager:
    """Manages configuration from environment variables"""
    
    def __init__(self):
        self.source_type = os.getenv('SOURCE_TYPE', 'local')
        
        # Kafka configuration
        self.kafka_brokers = os.getenv(
            'KAFKA_BROKERS',
            'k3s-vm1:30092,k3s-vm2:30093'
        ).split(',')
        
        # Source-specific configuration
        self.local_url = os.getenv('LOCAL_URL', 'http://adsb_receiver:8088/data/aircraft.json')
        self.regional_url = os.getenv('REGIONAL_URL', 'https://api.airplanes.live/v2/point/39.00000/-77.00000/500')
        self.global_url = os.getenv('GLOBAL_URL', 'https://re-api.adsb.lol/?all')
        
        # Polling intervals
        self.local_interval = int(os.getenv('LOCAL_INTERVAL', '2'))
        self.regional_interval = int(os.getenv('REGIONAL_INTERVAL', '15'))
        self.global_interval = int(os.getenv('GLOBAL_INTERVAL', '30'))
        
        self.validate()
    
    def validate(self):
        """Validate configuration"""
        valid_sources = ['local', 'regional', 'global']
        if self.source_type not in valid_sources:
            raise ValueError(f"SOURCE_TYPE must be one of {valid_sources}")

class KafkaPublisher:
    """Handles publishing to Kafka"""
    
    def __init__(self, config: ConfigManager):
        self.config = config
        self.producer = None
        self.connect()
    
    def connect(self):
        """Establish connection to Kafka with a wait loop to prevent crashloops"""
        while True:
            try:
                self.producer = KafkaProducer(
                    bootstrap_servers=self.config.kafka_brokers,
                    value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                    security_protocol='PLAINTEXT',
                    api_version=(3, 0, 0),
                    acks=1,
                    retries=10,
                    retry_backoff_ms=1000,
                    max_in_flight_requests_per_connection=1,
                    linger_ms=100,
                    batch_size=16384
                )
                logger.info(f"Connected to Kafka at {self.config.kafka_brokers}")
                break # Exit loop once connected
            except Exception as e:
                # If DNS or Kafka is down, we wait here. 
                # This prevents the script from ever reaching the 'fetch' logic.
                logger.error(f"Waiting for Kafka/DNS to be available: {e}")
                time.sleep(30)
    
    def on_success(self, record_metadata):
        """Record_metadata contains topic, partition, and offset"""
        logger.debug(f"Success: topic:{record_metadata.topic} "
                    f"partition:{record_metadata.partition} "
                    f"offset:{record_metadata.offset}")

    def on_error(self, excp):
        """This will catch the REAL error (e.g., NotLeader, Timeout, etc.)"""
        logger.error(f"Async send failed: {excp}", exc_info=True)

    def publish_batch(self, topic: str, data: List[Dict[str, Any]]):
        """Publish batch of records to Kafka topic"""
        if not data:
            return
        
        try:
            # Use single scrape_time for entire batch to identify scrape batches
            batch_scrape_time = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')

            for record in data:
                # Set batch scrape_time for all records
                record['scrape_time'] = batch_scrape_time

                future = self.producer.send(topic, value=record)
                future.add_callback(self.on_success)
                future.add_errback(self.on_error)
            
            # Flush to ensure all messages are sent
            self.producer.flush(timeout=10)
            logger.info(f"Published {len(data)} records to topic '{topic}'")
            
        except KafkaError as e:
            logger.error(f"Kafka error while publishing to {topic}: {e}")
            raise
        except Exception as e:
            logger.error(f"Failed to publish to {topic}: {e}")
            raise
    
    def close(self):
        """Close Kafka producer"""
        if self.producer:
            self.producer.close()

class LocalScraper:
    """Scrapes all available data from local Raspberry Pi ultrafeeder"""
    
    def __init__(self, config: ConfigManager):
        self.config = config
        self.url = config.local_url
    
    def fetch(self) -> List[Dict[str, Any]]:
        """Fetch and parse local aircraft data"""
        try:
            response = requests.get(self.url, timeout=3)
            response.raise_for_status()
            data = response.json()
            
            aircraft_list = []
            for ac in data.get('aircraft', []):
                # Skip aircraft without position
                if 'lat' not in ac or 'lon' not in ac:
                    continue
                
                aircraft = {
                    # Core identification
                    'hex': ac.get('hex', '').lower(),
                    'type': ac.get('type', ''),
                    'flight': ac.get('flight', '').strip(),
                    'r': ac.get('r', ''),
                    't': ac.get('t', ''),
                    'desc': ac.get('desc', ''),
                    # Position data
                    'lat': ac.get('lat'),
                    'lon': ac.get('lon'),
                    'alt_baro': ac.get('alt_baro'),
                    'alt_geom': ac.get('alt_geom'),
                    'gs': ac.get('gs'),
                    'track': ac.get('track'),
                    'baro_rate': ac.get('baro_rate'),
                    # Status
                    'squawk': ac.get('squawk', ''),
                    'emergency': ac.get('emergency', ''),
                    'category': ac.get('category', ''),
                    # Navigation
                    'nav_qnh': ac.get('nav_qnh'),
                    'nav_altitude_mcp': ac.get('nav_altitude_mcp'),
                    # Quality indicators
                    'nic': ac.get('nic'),
                    'rc': ac.get('rc'),
                    'version': ac.get('version'),
                    'nic_baro': ac.get('nic_baro'),
                    'nac_p': ac.get('nac_p'),
                    'nac_v': ac.get('nac_v'),
                    'sil': ac.get('sil'),
                    'sil_type': ac.get('sil_type', ''),
                    'gva': ac.get('gva'),
                    'sda': ac.get('sda'),
                    # Alerts
                    'alert': ac.get('alert'),
                    'spi': ac.get('spi'),
                    # Timing
                    'seen_pos': ac.get('seen_pos'),
                    'seen': ac.get('seen'),
                    # Local-specific fields
                    'rssi': ac.get('rssi'),
                    'messages': ac.get('messages'),
                    'r_dst': ac.get('r_dst'),
                    'r_dir': ac.get('r_dir'),
                    'ownOp': ac.get('ownOp', ''),
                    'year': ac.get('year', ''),
                    # Metadata
                    'source': 'local'
                }
                aircraft_list.append(aircraft)
            
            return aircraft_list
        
        except Exception as e:
            logger.error(f"Error fetching local data: {e}")
            return []

class RegionalScraper:
    """Scrapes regional (distance-bounded) data from airplanes.live regional API"""
    
    def __init__(self, config: ConfigManager):
        self.config = config
        self.url = config.regional_url
    
    def fetch(self) -> List[Dict[str, Any]]:
        """Fetch and parse regional aircraft data"""
        try:
            response = requests.get(self.url, timeout=5)
            response.raise_for_status()
            data = response.json()
            
            aircraft_list = []
            for ac in data.get('ac', []):
                # Skip aircraft without position
                if ac.get('lat') is None or ac.get('lon') is None:
                    continue
                
                aircraft = {
                    # Core identification
                    'hex': ac.get('hex', '').lower(),
                    'type': ac.get('type', ''),
                    'flight': ac.get('flight', '').strip(),
                    'r': ac.get('r', ''),
                    't': ac.get('t', ''),
                    'desc': ac.get('desc', ''),
                    # Position data
                    'lat': ac.get('lat'),
                    'lon': ac.get('lon'),
                    'alt_baro': ac.get('alt_baro'),
                    'alt_geom': ac.get('alt_geom'),
                    'gs': ac.get('gs'),
                    'track': ac.get('track'),
                    'baro_rate': ac.get('baro_rate'),
                    # Status
                    'squawk': ac.get('squawk', ''),
                    'emergency': ac.get('emergency', ''),
                    'category': ac.get('category', ''),
                    # Navigation
                    'nav_qnh': ac.get('nav_qnh'),
                    'nav_altitude_mcp': ac.get('nav_altitude_mcp'),
                    'nav_modes': ac.get('nav_modes', []),
                    # Quality indicators
                    'nic': ac.get('nic'),
                    'rc': ac.get('rc'),
                    'version': ac.get('version'),
                    'nic_baro': ac.get('nic_baro'),
                    'nac_p': ac.get('nac_p'),
                    'nac_v': ac.get('nac_v'),
                    'sil': ac.get('sil'),
                    'sil_type': ac.get('sil_type', ''),
                    'gva': ac.get('gva'),
                    'sda': ac.get('sda'),
                    # Alerts
                    'alert': ac.get('alert'),
                    'spi': ac.get('spi'),
                    # Timing
                    'seen_pos': ac.get('seen_pos'),
                    'seen': ac.get('seen'),
                    # Regional-specific fields
                    'rssi': ac.get('rssi'),
                    'messages': ac.get('messages'),
                    'dst': ac.get('dst'),
                    'dir': ac.get('dir'),
                    'ownOp': ac.get('ownOp', ''),
                    'year': ac.get('year', ''),
                    # Metadata
                    'source': 'regional'
                }
                aircraft_list.append(aircraft)
            
            return aircraft_list
        
        except Exception as e:
            logger.error(f"Error fetching regional data: {e}")
            return []

class GlobalScraper:
    """Scrapes all current data from adsb.lol global API"""
    
    def __init__(self, config: ConfigManager):
        self.config = config
        self.url = config.global_url
    
    def fetch(self) -> List[Dict[str, Any]]:
        """Fetch and parse global aircraft data"""
        try:
            response = requests.get(self.url, timeout=10)
            response.raise_for_status()
            data = response.json()
            
            aircraft_list = []
            for ac in data.get('aircraft', []):
                # Skip aircraft without position
                if ac.get('lat') is None or ac.get('lon') is None:
                    continue
                
                aircraft = {
                    # Core identification
                    'hex': ac.get('hex', '').lower(),
                    'type': ac.get('type', ''),
                    'flight': ac.get('flight', '').strip(),
                    'r': ac.get('r', ''),
                    't': ac.get('t', ''),
                    'desc': ac.get('desc', ''),
                    # Position data
                    'lat': ac.get('lat'),
                    'lon': ac.get('lon'),
                    'alt_baro': ac.get('alt_baro'),
                    'alt_geom': ac.get('alt_geom'),
                    'gs': ac.get('gs'),
                    'track': ac.get('track'),
                    'baro_rate': ac.get('baro_rate'),
                    # Status
                    'squawk': ac.get('squawk', ''),
                    'emergency': ac.get('emergency', ''),
                    'category': ac.get('category', ''),
                    # Navigation
                    'nav_qnh': ac.get('nav_qnh'),
                    'nav_altitude_mcp': ac.get('nav_altitude_mcp'),
                    'nav_modes': ac.get('nav_modes', []),
                    # Quality indicators
                    'nic': ac.get('nic'),
                    'rc': ac.get('rc'),
                    'version': ac.get('version'),
                    'nic_baro': ac.get('nic_baro'),
                    'nac_p': ac.get('nac_p'),
                    'nac_v': ac.get('nac_v'),
                    'sil': ac.get('sil'),
                    'sil_type': ac.get('sil_type', ''),
                    'gva': ac.get('gva'),
                    'sda': ac.get('sda'),
                    # Alerts
                    'alert': ac.get('alert'),
                    'spi': ac.get('spi'),
                    # Timing
                    'seen_pos': ac.get('seen_pos'),
                    'seen': ac.get('seen'),
                    # Global-specific fields
                    'rssi': ac.get('rssi'),
                    'messages': ac.get('messages'),
                    'dst': ac.get('dst'),
                    'dir': ac.get('dir'),
                    # Metadata
                    'source': 'global'
                }
                aircraft_list.append(aircraft)
            
            return aircraft_list
        
        except Exception as e:
            logger.error(f"Error fetching global data: {e}")
            return []

def main():
    """Main scraper loop with infrastructure guards"""
    config = ConfigManager()
    
    # Startup Settle: Prevents rapid-fire hits if K8s restarts the pod
    time.sleep(15)

    # Connect to Kafka before defining the scraper
    # Ensures we don't collect data we can't send
    publisher = KafkaPublisher(config)

    # Initialize appropriate scraper
    if config.source_type == 'local':
        scraper = LocalScraper(config)
        topic = 'flights-local'
        interval = config.local_interval
    elif config.source_type == 'regional':
        scraper = RegionalScraper(config)
        topic = 'flights-regional'
        interval = config.regional_interval
    elif config.source_type == 'global':
        scraper = GlobalScraper(config)
        topic = 'flights-global'
        interval = config.global_interval
    else:
        logger.error(f"Unknown source type: {config.source_type}")
        sys.exit(1)
    
    logger.info(f"Starting {config.source_type} scraper (interval: {interval}s, topic: {topic})")
    
    error_count = 0
    max_errors = 10
    
    try:
        while True:
            try:
                data = scraper.fetch()
                
                if data:
                    publisher.publish_batch(topic, data)
                    error_count = 0
                else:
                    logger.warning(f"No data fetched from {config.source_type}")
                
                time.sleep(interval)
            
            except Exception as e:
                error_count += 1
                logger.error(f"Error in main loop: {e}")
                
                if error_count >= max_errors:
                    logger.error(f"Too many consecutive errors ({max_errors}), exiting")
                    break
                
                sleep_time = min(interval * (2 ** error_count), 300)
                logger.info(f"Sleeping {sleep_time}s before retry...")
                time.sleep(sleep_time)
    
    except KeyboardInterrupt:
        logger.info("Shutting down gracefully...")
    
    finally:
        publisher.close()

if __name__ == '__main__':
    main()