# ── VPC ──────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.5"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true # Save cost — single NAT for demo
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for EKS and Karpenter subnet discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb"                              = 1
    "kubernetes.io/cluster/${var.project_name}-eks"        = "owned"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                     = 1
    "kubernetes.io/cluster/${var.project_name}-eks"        = "owned"
    "karpenter.sh/discovery"                              = "${var.project_name}-eks"
  }

  tags = var.tags
}
