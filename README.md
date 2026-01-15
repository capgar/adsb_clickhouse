# ADS-B Position Collection on ClickHouse

## Overview

Nearly every commercial airliner, as well as a large percentage of private, government, and even some military aircraft,
constantly broadcast their position to a network of listening stations.  These, in turn, relay the position reports to
a variety of commercial and privately-run networks which aggregate and share the collected position data.  At any given
time, there are between 9000-12000 aircraft broadcasting their position through high frequency VHF signals.  While there
are many websites which display ADS-B based position data, it is also possible to collect and aggregate that same data
for free.

The purpose of this project (in additon to meeting a professional need to be able to quickly deploy and test data ingestion 
pipelines) is to explore the use of ClickHouse as an ideal repository for ADS-B data for storage, aggregation, and analytics,
potentially over very long timeframes.

At the time of the initial GitHub push, this project consists of a couple small VMs running on miscellaneous computers in my 
house, and hosting containers through K3s.  They are fed local aircraft position data which they stream from a Raspberry Pi 
mounted up in my attic.  The Pi is hooked up to a cheap VHF antenna, where it collects postition reports from the stream of internaitonal flights on their way in and out of Dulles International.  This data is, in turn, streamed out to a dozen or so 
public ADS-B aggregation sites.

Additionally, I am currently scraping ADS-B data from two public providers, bringing in regional flight positions several 
times per minute, and global positions (all tracked flights) less frequently.  More sources will be added, but at this time, 
I'm keeping the volume low - all said, only a couple million position reports an hour.  But there are also opportunities to 
increase that volume over time.

This repository contains Kubernetes manifests for deploying:
- **ADS-B Scrapers**: A simple Python-based container which ingests position data from a variety of sources,
  and ingests it into Kafka
- **Kafka + Zookeeper**: Kafka broker with TLS-enabled external access and mTLS authentication.
  (Soon to be replaced with Redpanda)
- **Clickhouse + Keepers**: Built with the Altinity ClickHouse Operator, I have a single node running locally,
  and am standing up others as testbeds in AWS/EKS, and elsewhere
- **Grafana + Prometheus**: Grafana provides live visibility into the various ADS-B data streams, including real-time world
  map views. Additional dashboards enabled through the Altinity Operator, provide system health and performance metrics.

## Prerequisites

### Kubernetes Cluster
I chose k3s for my homelab, but this should work with any k8s-like distribution

### Certificates
See certs/README.md for notes on certificate management for Clickhouse -> Kafka. Place these in the `certs/` directory (gitignored).

## Container Image
Build and import the scraper image:
```bash
cd ~/adsb-scraper
docker build -t adsb-scraper:latest .
docker save adsb-scraper:latest | sudo k3s ctr images import -
```
For AWS deployment, you'll want to push this to a registry (ECR or Docker Hub).

## Setup
Coming soon!
