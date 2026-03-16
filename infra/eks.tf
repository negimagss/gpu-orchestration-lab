# ── EKS Cluster ──────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = "${var.project_name}-eks"
  cluster_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint for kubectl access during demo
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Enable IRSA for service accounts (Karpenter, etc.)
  enable_irsa = true

  # Cluster addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  # Managed node group — CPU workloads (Qdrant, Airflow, Jaeger, OTel)
  eks_managed_node_groups = {
    cpu_workers = {
      name           = "${var.project_name}-cpu"
      instance_types = [var.eks_node_instance_type]

      min_size     = var.eks_node_min_size
      max_size     = var.eks_node_max_size
      desired_size = var.eks_node_desired_size

      labels = {
        workload = "general"
        role     = "cpu-worker"
      }

      tags = merge(var.tags, {
        "karpenter.sh/discovery" = "${var.project_name}-eks"
      })
    }
  }

  # Allow Karpenter role to join nodes
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  # Access entries for cluster admin
  enable_cluster_creator_admin_permissions = true

  tags = merge(var.tags, {
    "karpenter.sh/discovery" = "${var.project_name}-eks"
  })
}

# ── NVIDIA Device Plugin (required for GPU pods) ──
resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = "kube-system"
  version    = "0.14.5"

  set {
    name  = "nodeSelector.karpenter\\.sh/nodepool"
    value = "gpu-inference"
  }

  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [module.eks]
}
