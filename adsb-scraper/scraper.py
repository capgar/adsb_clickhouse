#!/usr/bin/env python3
"""
------------------------------------------------------------------------------------
ADS-B Aircraft Data Scraper with Kafka Integration
Polls multiple sources for current aircraft position data
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
from datetime import datetime, timezone, timedelta
from typing import List, Dict, Any, Optional
from itertools import cycle
from kafka import KafkaProducer
from kafka.errors import KafkaError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class RateLimitException(Exception):
    """Raised when API returns rate limit or forbidden response"""
    pass

class ConfigManager:
    """Manages configuration from environment variables"""
    
    def __init__(self):
        self.source_type = os.getenv('SOURCE_TYPE', 'local')
        self.source_name = os.getenv('SOURCE_NAME', 'local')
        
        # Kafka configuration
        self.kafka_brokers = os.getenv(
            'KAFKA_BROKERS',
            'k3s-vm1:30092,k3s-vm2:30093'
        ).split(',')
        
        # Kafka topic (externally configurable)
        self.kafka_topic = os.getenv('KAFKA_TOPIC')
        if not self.kafka_topic:
            raise ValueError("KAFKA_TOPIC environment variable must be set")
        
        # Parse SOURCE_URLS (JSON array or comma-separated)
        urls_str = os.getenv('SOURCE_URLS')
        if not urls_str:
            raise ValueError("SOURCE_URLS environment variable must be set")
        
        # Try parsing as JSON array first
        try:
            self.source_urls = json.loads(urls_str)
            if not isinstance(self.source_urls, list):
                raise ValueError("SOURCE_URLS must be a JSON array or comma-separated string")
        except json.JSONDecodeError:
            # Fall back to comma-separated
            self.source_urls = [url.strip() for url in urls_str.split(',') if url.strip()]
        
        if not self.source_urls:
            raise ValueError("SOURCE_URLS must contain at least one URL")
        
        # Polling interval
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '10'))
        
        # Rate limiting configuration
        self.startup_settle_time = int(os.getenv('STARTUP_SETTLE_TIME', '15'))
        self.post_kafka_settle_time = int(os.getenv('POST_KAFKA_SETTLE_TIME', '10'))
        self.max_consecutive_errors = int(os.getenv('MAX_CONSECUTIVE_ERRORS', '10'))
        
        # OpenSky OAuth2 credentials (only required for global-opensky)
        self.opensky_client_id = os.getenv('OPENSKY_CLIENT_ID')
        self.opensky_client_secret = os.getenv('OPENSKY_CLIENT_SECRET')
        
        self.validate()

    def validate(self):
        """Validate configuration"""
        valid_sources = ['local', 'regional', 'global-stream', 'global-opensky']
        if self.source_type not in valid_sources:
            raise ValueError(f"SOURCE_TYPE must be one of {valid_sources}")
        
        # Validate OpenSky credentials if needed
        if self.source_type == 'global-opensky':
            if not self.opensky_client_id or not self.opensky_client_secret:
                raise ValueError("OPENSKY_CLIENT_ID and OPENSKY_CLIENT_SECRET required for global-opensky")

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
            for record in data:
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
    """Scrapes all available data from local Raspberry Pi ultrafeeder http API"""
    
    def __init__(self, config: ConfigManager):
        self.config = config
        self.name = config.source_name
        self.urls = config.source_urls
        self.url_cycle = cycle(self.urls)
        logger.info(f"Initialized local scraper with {len(self.urls)} URL(s): {self.urls}")
    
    def fetch(self) -> List[Dict[str, Any]]:
        """Fetch and parse position data"""
        url = next(self.url_cycle)
        logger.info(f"Fetching from: {url}")
        
        try:
            response = requests.get(url, timeout=2)
            scrape_time = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            
            # Check for rate limiting or forbidden responses
            if response.status_code == 429:
                logger.warning(f"Rate limited (429) from {url}")
                raise RateLimitException(f"Rate limited by {url}")
            elif response.status_code == 403:
                logger.warning(f"Forbidden (403) from {url}")
                raise RateLimitException(f"Forbidden response from {url}")
            
            response.raise_for_status()
            data = response.json()
            
            position_list = []
            for ac in data.get('aircraft', []):
                # Skip aircraft without position
                if 'lat' not in ac or 'lon' not in ac:
                    continue
                
                aircraft = {
                    # Identification
                    'hex': ac.get('hex'), #str
                    'type': ac.get('type'), #str
                    'flight': ac.get('flight'), #str
                    'r': ac.get('r'), #str
                    't': ac.get('t'), #str
                    'desc': ac.get('desc'), #str
                    'ownOp': ac.get('ownOp'), #str
                    'year': ac.get('year'), #str
                    # Position & Movement
                    'lat': ac.get('lat'), #float64
                    'lon': ac.get('lon'), #float64
                    'alt_baro': ac.get('alt_baro'), #int or str (ground)
                    'alt_geom': ac.get('alt_geom'), #int
                    'gs': ac.get('gs'), #float
                    'track': ac.get('track'), #float
                    'track_rate': ac.get('track_rate'), #float
                    'roll': ac.get('roll'), #float
                    'mag_heading': ac.get('mag_heading'), #float
                    'true_heading': ac.get('true_heading'), #float
                    'baro_rate': ac.get('baro_rate'), #int
                    'geom_rate': ac.get('geom_rate'), #int
                    # Relative Position Data
                    'r_dst': ac.get('r_dst'), #float
                    'r_dir': ac.get('r_dir'), #float
                    # Weather & Advanced Performance
                    'ias': ac.get('ias'), #int
                    'tas': ac.get('tas'), #int
                    'mach': ac.get('mach'), #float
                    'oat': ac.get('oat'), #int
                    'tat': ac.get('tat'), #int
                    'ws': ac.get('ws'), #int
                    'wd': ac.get('wd'), #int
                    # Status
                    'squawk': ac.get('squawk'), #str
                    'emergency': ac.get('emergency'), #str
                    'category': ac.get('category'), #str
                    'alert': ac.get('alert'), #bool
                    'spi': ac.get('spi'), #bool
                    # Navigation
                    'nav_qnh': ac.get('nav_qnh'), #float
                    'nav_altitude_mcp': ac.get('nav_altitude_mcp'), #int
                    'nav_altitude_fms': ac.get('nav_altitude_fms'), #int
                    'nav_heading': ac.get('nav_heading'), #float
                    'nav_modes': ac.get('nav_modes', []), #array(str)
                    # Data Integrity (Aircraft)
                    'version': ac.get('version'), #int
                    'nic': ac.get('nic'), #int
                    'rc': ac.get('rc'), #int
                    'nic_baro': ac.get('nic_baro'), #int
                    'nac_p': ac.get('nac_p'), #int
                    'nac_v': ac.get('nac_v'), #int
                    'sil': ac.get('sil'), #int
                    'sil_type': ac.get('sil_type'), #str
                    'gva': ac.get('gva'), #int
                    'sda': ac.get('sda'), #int
                    'dbFlags': ac.get('dbFlags'), #int
                    # Signal & Physical (Receiver)
                    'rssi': ac.get('rssi'), #float
                    'messages': ac.get('messages'), #int
                    'mlat': ac.get('mlat', []), #array(str)
                    'tisb': ac.get('tisb', []), #array(str)
                    # State Persistence & Diagnosis (Receiver)
                    'seen_pos': ac.get('seen_pos'), #float
                    'seen': ac.get('seen'), #float
                    'lastPosition': ac.get('lastPosition'), #json array (lat, lon, nic, rc, seen_pos)
                    'calc_track': ac.get('calc_track'), #int
                    'gpsOkLat': ac.get('gpsOkLat'), #float64
                    'gpsOkLon': ac.get('gpsOkLon'), #float64
                    'gpsOkBefore': ac.get('gpsOkBefore'), #float64
                    # Scraper metadata
                    'source': self.name,
                    'scrape_time': scrape_time
                }

                position_list.append(aircraft)
            
            logger.info(f"Parsed {len(position_list)} aircraft from {self.name}")
            return position_list
        
        except RateLimitException:
            # Re-raise rate limit exceptions
            raise
        except Exception as e:
            logger.error(f"Error fetching local data from {url}: {e}")
            raise

class RegionalScraper:
    """Scrapes regional data from airplanes.live http API"""
    
    def __init__(self, config: ConfigManager):
        self.config = config
        self.name = config.source_name
        self.urls = config.source_urls
        self.url_cycle = cycle(self.urls)
        logger.info(f"Initialized regional scraper with {len(self.urls)} URL(s): {self.urls}")

    def fetch(self) -> List[Dict[str, Any]]:
        """Fetch and parse position data"""
        url = next(self.url_cycle)
        logger.info(f"Fetching from: {url}")
        
        try:
            response = requests.get(url, timeout=10)
            scrape_time = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            
            # Check for rate limiting or forbidden responses
            if response.status_code == 429:
                logger.warning(f"Rate limited (429) from {url}")
                raise RateLimitException(f"Rate limited by {url}")
            elif response.status_code == 403:
                logger.warning(f"Forbidden (403) from {url}")
                raise RateLimitException(f"Forbidden response from {url}")
            
            response.raise_for_status()
            data = response.json()
            
            position_list = []
            for ac in data.get('ac', []):
                # Skip aircraft without position
                if ac.get('lat') is None or ac.get('lon') is None:
                    continue
                
                aircraft = {
                    # Identification
                    'hex': ac.get('hex'), #str
                    'type': ac.get('type'), #str
                    'flight': ac.get('flight'), #str
                    'r': ac.get('r'), #str
                    't': ac.get('t'), #str
                    'desc': ac.get('desc'), #str
                    'ownOp': ac.get('ownOp'), #str
                    'year': ac.get('year'), #str
                    # Position & Movement
                    'lat': ac.get('lat'), #float64
                    'lon': ac.get('lon'), #float64
                    'alt_baro': ac.get('alt_baro'), #int or str (ground)
                    'alt_geom': ac.get('alt_geom'), #int
                    'gs': ac.get('gs'), #float
                    'track': ac.get('track'), #float
                    'mag_heading': ac.get('mag_heading'), #float
                    'true_heading': ac.get('true_heading'), #float
                    'nav_heading': ac.get('nav_heading'), #float
                    'baro_rate': ac.get('baro_rate'), #int
                    'geom_rate': ac.get('geom_rate'), #int
                    # Relative Position Data
                    'dst': ac.get('dst'), #float
                    'dir': ac.get('dir'), #float
                    # Weather & Advanced Performance
                    'ias': ac.get('ias'), #int
                    'mach': ac.get('mach'), #float
                    # Status
                    'squawk': ac.get('squawk'), #str
                    'emergency': ac.get('emergency'), #str
                    'category': ac.get('category'), #str
                    'alert': ac.get('alert'), #bool
                    'spi': ac.get('spi'), #bool
                    # Navigation
                    'nav_qnh': ac.get('nav_qnh'), #float
                    'nav_altitude_mcp': ac.get('nav_altitude_mcp'), #int
                    'nav_altitude_fms': ac.get('nav_altitude_fms'), #int
                    'nav_modes': ac.get('nav_modes', []), #array(str)
                    # Data Integrity (Aircraft)
                    'version': ac.get('version'), #int
                    'nic': ac.get('nic'), #int
                    'rc': ac.get('rc'), #int
                    'nic_baro': ac.get('nic_baro'), #int
                    'nac_p': ac.get('nac_p'), #int
                    'nac_v': ac.get('nac_v'), #int
                    'sil': ac.get('sil'), #int
                    'sil_type': ac.get('sil_type'), #str
                    'gva': ac.get('gva'), #int
                    'sda': ac.get('sda'), #int
                    'dbFlags': ac.get('dbFlags'), #int
                    # Signal & Physical (Receiver)
                    'rssi': ac.get('rssi'), #float
                    'messages': ac.get('messages'), #int
                    'mlat': ac.get('mlat', []), #array(str)
                    'tisb': ac.get('tisb', []), #array(str)
                    # State Persistence & Diagnosis (Receiver)
                    'seen_pos': ac.get('seen_pos'), #float
                    'seen': ac.get('seen'), #float
                    # Scraper metadata
                    'source': self.name,
                    'scrape_time': scrape_time
                }

                position_list.append(aircraft)
            
            logger.info(f"Parsed {len(position_list)} aircraft from {self.name}")
            return position_list
        
        except RateLimitException:
            # Re-raise rate limit exceptions
            raise
        except Exception as e:
            logger.error(f"Error fetching regional data from {url}: {e}")
            raise

class GlobalStreamScraper:
    """Scrapes all current positions from adsb.lol stream via local readsb HTTP API"""
    
    def __init__(self, config: ConfigManager):
        self.config = config
        self.name = config.source_name
        self.urls = config.source_urls
        self.url_cycle = cycle(self.urls)
        logger.info(f"Initialized global-stream scraper with {len(self.urls)} URL(s): {self.urls}")
    
    def fetch(self) -> List[Dict[str, Any]]:
        """Fetch and parse position data"""
        url = next(self.url_cycle)
        logger.info(f"Fetching from: {url}")
        
        try:
            response = requests.get(url, timeout=10)
            scrape_time = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            
            # Check for rate limiting or forbidden responses
            if response.status_code == 429:
                logger.warning(f"Rate limited (429) from {url}")
                raise RateLimitException(f"Rate limited by {url}")
            elif response.status_code == 403:
                logger.warning(f"Forbidden (403) from {url}")
                raise RateLimitException(f"Forbidden response from {url}")
            
            response.raise_for_status()
            data = response.json()
            
            position_list = []
            for ac in data.get('aircraft', []):
                # Skip aircraft without position
                if ac.get('lat') is None or ac.get('lon') is None:
                    continue
                
                aircraft = {
                    # Identification
                    'hex': ac.get('hex'), #str
                    'type': ac.get('type'), #str
                    'flight': ac.get('flight'), #str
                    # Position & Movement
                    'lat': ac.get('lat'), #float64
                    'lon': ac.get('lon'), #float64
                    'alt_baro': ac.get('alt_baro'), #int or str (ground)
                    'alt_geom': ac.get('alt_geom'), #int
                    'gs': ac.get('gs'), #float
                    'track': ac.get('track'), #float
                    'track_rate': ac.get('track_rate'), #float
                    'roll': ac.get('roll'), #float
                    'mag_heading': ac.get('mag_heading'), #float
                    'true_heading': ac.get('true_heading'), #float
                    'baro_rate': ac.get('baro_rate'), #int
                    'geom_rate': ac.get('geom_rate'), #int
                    # Weather & Advanced Performance
                    'ias': ac.get('ias'), #int
                    'tas': ac.get('tas'), #int
                    'mach': ac.get('mach'), #float
                    'oat': ac.get('oat'), #int
                    'tat': ac.get('tat'), #int
                    'ws': ac.get('ws'), #int
                    'wd': ac.get('wd'), #int
                    # Status
                    'squawk': ac.get('squawk'), #str
                    'emergency': ac.get('emergency'), #str
                    'category': ac.get('category'), #str
                    'alert': ac.get('alert'), #bool
                    'spi': ac.get('spi'), #bool
                    # Navigation
                    'nav_qnh': ac.get('nav_qnh'), #float
                    'nav_altitude_mcp': ac.get('nav_altitude_mcp'), #int
                    'nav_altitude_fms': ac.get('nav_altitude_fms'), #int
                    'nav_heading': ac.get('nav_heading'), #float
                    'nav_modes': ac.get('nav_modes', []), #array(str)
                    # Data Integrity (Aircraft)
                    'version': ac.get('version'), #int
                    'nic': ac.get('nic'), #int
                    'rc': ac.get('rc'), #int
                    'nic_baro': ac.get('nic_baro'), #int
                    'nac_p': ac.get('nac_p'), #int
                    'nac_v': ac.get('nac_v'), #int
                    'sil': ac.get('sil'), #int
                    'sil_type': ac.get('sil_type'), #str
                    'gva': ac.get('gva'), #int
                    'sda': ac.get('sda'), #int
                    # Signal & Physical (Receiver)
                    'rssi': ac.get('rssi'), #float
                    'messages': ac.get('messages'), #int
                    'mlat': ac.get('mlat', []), #array(str)
                    'tisb': ac.get('tisb', []), #array(str)
                    # State Persistence & Diagnosis (Receiver)
                    'seen_pos': ac.get('seen_pos'), #float
                    'seen': ac.get('seen'), #float
                    'lastPosition': ac.get('lastPosition'), #json array (lat, lon, nic, rc, seen_pos)
                    'calc_track': ac.get('calc_track'), #int
                    'gpsOkLat': ac.get('gpsOkLat'), #float64
                    'gpsOkLon': ac.get('gpsOkLon'), #float64
                    'gpsOkBefore': ac.get('gpsOkBefore'), #float64
                    # Scraper metadata
                    'source': self.name,
                    'scrape_time': scrape_time
                }

                position_list.append(aircraft)
            
            logger.info(f"Parsed {len(position_list)} aircraft from {self.name}")
            return position_list
        
        except RateLimitException:
            # Re-raise rate limit exceptions
            raise
        except Exception as e:
            logger.error(f"Error fetching global-stream data from {url}: {e}")
            raise


class OpenSkyOAuth2:
    """Handles OAuth2 authentication for OpenSky Network HTTP API"""
    
    def __init__(self, client_id: str, client_secret: str):
        self.client_id = client_id
        self.client_secret = client_secret
        self.token_url = "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"
        self.access_token = None
        self.token_expiry = None
    
    def get_access_token(self) -> str:
        """
        Get or refresh OAuth2 access token.
        Tokens are valid for 30 minutes, we cache them for 25 minutes.
        """
        # Return cached token if still valid
        if self.access_token and self.token_expiry and datetime.now() < self.token_expiry:
            return self.access_token
        
        # Request new token
        logger.info("Requesting new OpenSky OAuth2 token...")
        payload = {
            'grant_type': 'client_credentials',
            'client_id': self.client_id,
            'client_secret': self.client_secret
        }
        
        try:
            response = requests.post(
                self.token_url,
                headers={'Content-Type': 'application/x-www-form-urlencoded'},
                data=payload,
                timeout=10
            )
            response.raise_for_status()
            
            token_data = response.json()
            self.access_token = token_data['access_token']
            # Cache token for 25 minutes (5 min before 30 min expiry)
            self.token_expiry = datetime.now() + timedelta(minutes=25)
            
            logger.info("OAuth2 token acquired successfully")
            return self.access_token
            
        except Exception as e:
            logger.error(f"Failed to get OAuth2 token: {e}")
            raise


class GlobalOpenSkyScraper:
    """
    Scrapes global aircraft data from OpenSky Network API.
    Uses OAuth2 for authentication (required for accounts created after March 2025).
    
    Note: OpenSky uses METRIC units (meters, m/s) unlike other sources (feet, knots)
    """
    
    def __init__(self, config: ConfigManager):
        self.config = config
        self.name = config.source_name
        self.urls = config.source_urls
        self.url_cycle = cycle(self.urls)
        logger.info(f"Initialized global-opensky scraper with {len(self.urls)} URL(s): {self.urls}")
        
        # Initialize OAuth2
        if not config.opensky_client_id or not config.opensky_client_secret:
            raise ValueError("OPENSKY_CLIENT_ID and OPENSKY_CLIENT_SECRET must be set")
        
        self.oauth = OpenSkyOAuth2(config.opensky_client_id, config.opensky_client_secret)
        logger.info(f"Initialized global-opensky scraper with OAuth2 authentication")
    
    def fetch(self) -> List[Dict[str, Any]]:
        """Fetch and parse OpenSky state vectors"""
        url = next(self.url_cycle)
        logger.info(f"Fetching from: {url}")
        
        try:
            # Get OAuth2 token
            token = self.oauth.get_access_token()
            
            headers = {
                'Authorization': f'Bearer {token}'
            }
            response = requests.get(
                url,
                headers=headers,
                timeout=30
            )
            scrape_time = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
            
            # Check for rate limiting
            if response.status_code == 429:
                retry_after = response.headers.get('x-rate-limit-retry-after-seconds', 'unknown')
                logger.warning(f"Rate limited (429). Retry after: {retry_after}s")
                raise RateLimitException(f"Rate limited by OpenSky. Retry after: {retry_after}s")
            elif response.status_code == 403:
                logger.warning("Forbidden (403) - possible authentication issue")
                raise RateLimitException("Forbidden response from OpenSky")
            
            response.raise_for_status()
            data = response.json()
            
            # Log rate limit status
            remaining_credits = response.headers.get('x-rate-limit-remaining')
            if remaining_credits:
                logger.info(f"OpenSky credits remaining: {remaining_credits}")
            
            # Parse state vectors
            position_list = []
            time = data.get('time', []) # interval [time-1, time] in which state vectors are associated
            states = data.get('states', []) # state vectors of aircraft position within time interval
            
            for state in states:
                # Skip aircraft without position
                if state[5] is None or state[6] is None:  # drop records with no lat/lon
                    continue
                
                # Field definitions - Specific to OpenSky
                aircraft = {
                    'icao24': (state[0] or ''),  # str: unique 24-bit address in hex
                    'callsign': (state[1] or ''), # str: 8 char callsign, can be null
                    'origin_country': (state[2] or '').strip(), # str: country name inferred from iao24
                    'time_position': state[3], # int: unix timestamp for last position update or null
                    'last_contact': state[4], # int: unix timestamp of last update in general
                    'lon': state[5],  # float: longitude, can be null (nulls currently dropped)
                    'lat': state[6],  # float: latitude, can be null (nulls currently dropped)
                    'baro_altitude': state[7],  # float: baro altitude (m), null if on ground
                    'on_ground': state[8], #boolean: true if a surface position report
                    'velocity': state[9],  # float: velocity over ground in m/s, can be null
                    'true_track': state[10], # float: true_track in degrees, can be null
                    'vertical_rate': state[11], # float: vertical_rate (m/s), can be null
                    'sensors': state[12] if state[12] is not None else [], # int: IDs of receivers which contributed to vector, can be null
                    'geo_altitude': state[13], # float: geo altitude in (m)
                    'squawk': (state[14] or ''), # string: transponder code, can be null
                    'spi': 1 if state[15] else 0,  # boolean: special purpose indicator
                    'position_source': state[16], # int: position origin category, see opensky-api for list
                    #'category': state[17], DEPRECATED int: aircraft type category, see opensky-api for list
                    # Scraper Metadata
                    'source': self.name,
                    'scrape_time': scrape_time
                }
                position_list.append(aircraft)
            
            logger.info(f"Parsed {len(position_list)} aircraft from {self.name}")
            return position_list
        
        except RateLimitException:
            # Re-raise rate limit exceptions
            raise
        except Exception as e:
            logger.error(f"Error fetching OpenSky data: {e}")
            raise


def main():
    """Main scraper loop with infrastructure guards"""
    config = ConfigManager()
    
    # Startup Settle: Prevents rapid-fire hits if K8s restarts the pod
    logger.info(f"Initial startup settle: sleeping {config.startup_settle_time}s")
    time.sleep(config.startup_settle_time)

    # Connect to Kafka before defining the scraper
    # Ensures we don't collect data we can't send
    publisher = KafkaPublisher(config)
    
    # Additional settle time after Kafka connection to ensure minimum time between restarts
    logger.info(f"Post-Kafka settle: sleeping {config.post_kafka_settle_time}s")
    time.sleep(config.post_kafka_settle_time)

    # Initialize appropriate scraper based on source type
    if config.source_type == 'local':
        scraper = LocalScraper(config)
    elif config.source_type == 'regional':
        scraper = RegionalScraper(config)
    elif config.source_type == 'global-stream':
        scraper = GlobalStreamScraper(config)
    elif config.source_type == 'global-opensky':
        scraper = GlobalOpenSkyScraper(config)
    else:
        logger.error(f"Unknown source type: {config.source_type}")
        sys.exit(1)
    
    logger.info(f"Starting {config.source_type} scraper")
    logger.info(f"  Source URLS: {config.source_urls}")
    logger.info(f"  Kafka Topic: {config.kafka_topic}")
    logger.info(f"  Poll Interval: {config.poll_interval}s")
    
    error_count = 0
    rate_limit_backoff = 0
    
    try:
        while True:
            try:
                # Apply rate limit backoff if we've been rate limited
                if rate_limit_backoff > 0:
                    logger.info(f"Rate limit backoff: sleeping {rate_limit_backoff}s")
                    time.sleep(rate_limit_backoff)
                    rate_limit_backoff = 0
                
                data = scraper.fetch()
                
                if data:
                    publisher.publish_batch(config.kafka_topic, data)
                    error_count = 0
                else:
                    logger.warning(f"No data fetched from {config.source_type}")
                
                time.sleep(config.poll_interval)
            
            except RateLimitException as e:
                # Special handling for rate limit errors
                error_count += 1
                logger.error(f"Rate limit error: {e}")
                
                # Exponential backoff for rate limiting, but cap at 5 minutes
                rate_limit_backoff = min(config.poll_interval * (2 ** error_count), 300)
                logger.warning(f"Will apply {rate_limit_backoff}s backoff on next iteration")
                
                if error_count >= config.max_consecutive_errors:
                    logger.error(f"Too many consecutive rate limit errors ({config.max_consecutive_errors}), exiting")
                    break
                
                # Sleep the normal interval before next attempt
                time.sleep(config.poll_interval)
            
            except Exception as e:
                error_count += 1
                logger.error(f"Error in main loop: {e}")
                
                if error_count >= config.max_consecutive_errors:
                    logger.error(f"Too many consecutive errors ({config.max_consecutive_errors}), exiting")
                    break
                
                # Exponential backoff for general errors, capped at 5 minutes
                sleep_time = min(config.poll_interval * (2 ** error_count), 300)
                logger.info(f"Sleeping {sleep_time}s before retry...")
                time.sleep(sleep_time)
    
    except KeyboardInterrupt:
        logger.info("Shutting down gracefully...")
    
    finally:
        publisher.close()

if __name__ == '__main__':
    main()
