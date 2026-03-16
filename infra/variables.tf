variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-2" # Ohio
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "inferops"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "demo"
}

# ── VPC ──────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# ── EKS ──────────────────────────────────────────
variable "eks_cluster_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.29"
}

variable "eks_node_instance_type" {
  description = "Instance type for EKS managed node group (CPU workloads)"
  type        = string
  default     = "t3.large"
}

variable "eks_node_min_size" {
  description = "Minimum number of nodes in the managed node group"
  type        = number
  default     = 2
}

variable "eks_node_max_size" {
  description = "Maximum number of nodes in the managed node group"
  type        = number
  default     = 4
}

variable "eks_node_desired_size" {
  description = "Desired number of nodes in the managed node group"
  type        = number
  default     = 2
}

# ── GPU (Karpenter) ──────────────────────────────
variable "gpu_instance_types" {
  description = "GPU instance types for Karpenter to provision"
  type        = list(string)
  default     = ["g5.xlarge"]
}

# ── EC2 (App Server) ────────────────────────────
variable "ec2_instance_type" {
  description = "Instance type for the app server (Go + Python)"
  type        = string
  default     = "t3.medium"
}

variable "ec2_key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = ""
}

# ── Tags ─────────────────────────────────────────
variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "InferOps"
    Environment = "demo"
    ManagedBy   = "terraform"
  }
}
