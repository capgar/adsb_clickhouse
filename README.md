# ADS-B Position Collection on ClickHouse
![--------------------------------------------------](docs/adsb_clickhouse.png)

## Overview

At any time, there may be over 12000 aircraft broadcasting their position through high frequency VHF signals. 
Nearly every commercial airliner and most civilian aircraft continuously stream their positions to a
network of listening stations.  These stations, in turn, relay this data to a variety of commercial and 
privately-run networks which aggregate and share the collected position data.

This project leverages ClickHouse, an efficient and scalable columnmar database, to consume ADS-B data from a
variety of sources.  In addition to collecting real-time signals from local commercial aircraft in my local area,
it also polls worldwide position data from multiple online sources at varying polling rates.  The current
volume is only a couple million position reports per hour, which easily runs in containers on home PCs.
The ClickHouse cluster is being migrated to AWS, where it is being scaled up to handle larger load.  The core 
data feeds (and Kafka pipeline) will continue to feed from my house.

This repository contains Kubernetes manifests for deploying:
- **ADS-B Scrapers**: A simple Python-based container which ingests position data from a variety of sources,
  and ingests it into Kafka
- **Kafka + Zookeeper**: Kafka broker with TLS-enabled external access and mTLS authentication.
  (Soon to be replaced with Redpanda)
- **Clickhouse + Keepers**: Built with the Altinity ClickHouse Operator, I have a single node running locally,
  and am standing up others as testbeds in AWS/EKS, and elsewhere
- **Grafana + Prometheus**: Grafana provides live visibility into the various ADS-B data streams, including real-time world
  map views. Additional dashboards enabled through the Altinity Operator, provide system health and performance metrics.

Additionally, Terraform automation for standing up infrastructure in EKS, and Ansible automation is being added.

## Prerequisites

### Kubernetes
I chose k3s in my homelab, but this should work with any k8s-like distribution

### Container Image
Build and import the scraper image:
```bash
cd ~/adsb-scraper
docker build -t adsb-scraper:latest .
docker save adsb-scraper:latest | sudo k3s ctr images import -
```
For AWS deployment, you'll want to push this to a registry (ECR or Docker Hub)

## Setup
Manual kubernetes manifest deployments, with automated EKS deployment of the Clickhouse and monitoring components in progress.
Procedures coming shortly.
