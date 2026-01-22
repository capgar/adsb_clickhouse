# main.tf
# Root module for ADSB EKS Lab environment
# This creates a complete, cost-optimized EKS cluster on Graviton (ARM) instances

terraform {
  required_version = ">= 1.6"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }

  # S3 backend for state storage
  # NOTE: Run with local backend first to create the S3 bucket,
  # then uncomment this and run terraform init -migrate-state
  # backend "s3" {
  #   bucket         = "adsb-eks-terraform-state"
  #   key            = "eks-cluster/terraform.tfstate"
  #   region         = "us-east-2"
  #   encrypt        = true
  #   dynamodb_table = "adsb-eks-terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "adsb-eks-lab"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

# Kubernetes provider configured after EKS cluster creation
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name,
      "--region",
      var.aws_region
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        module.eks.cluster_name,
        "--region",
        var.aws_region
      ]
    }
  }
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# VPC Module
module "vpc" {
  source = "./modules/vpc"

  cluster_name         = var.cluster_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = slice(data.aws_availability_zones.available.names, 0, 3)
  single_nat_gateway   = var.single_nat_gateway
}

# EKS Module
module "eks" {
  source = "./modules/eks"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids
  
  node_groups     = var.node_groups
}

# EBS CSI Driver Module
module "ebs_csi" {
  source = "./modules/ebs-csi"

  cluster_name                = module.eks.cluster_name
  cluster_oidc_provider_arn   = module.eks.oidc_provider_arn
  cluster_oidc_provider_url   = module.eks.oidc_provider_url
}

# Storage Classes
module "storage" {
  source = "./modules/storage"

  depends_on = [module.ebs_csi]
}

# S3 Buckets for state and backups
module "s3" {
  source = "./modules/s3"

  cluster_name = var.cluster_name
}

# IAM role for ClickHouse to access S3 backups
module "clickhouse_s3_access" {
  source = "./modules/clickhouse-s3-irsa"

  cluster_name              = module.eks.cluster_name
  cluster_oidc_provider_arn = module.eks.oidc_provider_arn
  cluster_oidc_provider_url = module.eks.oidc_provider_url
  backup_bucket_arn         = module.s3.clickhouse_backup_bucket_arn
}
