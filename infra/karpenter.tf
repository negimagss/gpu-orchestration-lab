# ── Karpenter Controller ─────────────────────────
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.8"

  cluster_name = module.eks.cluster_name

  # IRSA for Karpenter controller
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  # Node IAM role for Karpenter-provisioned nodes
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "0.35.0"

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.iam_role_arn
  }

  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }

  depends_on = [module.eks]
}

# ── GPU NodePool (Karpenter) ─────────────────────
resource "kubectl_manifest" "gpu_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: gpu-inference
    spec:
      amiFamily: AL2
      role: "${module.karpenter.node_iam_role_name}"
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${module.eks.cluster_name}"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${module.eks.cluster_name}"
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 100Gi
            volumeType: gp3
            deleteOnTermination: true
      tags:
        Name: "${var.project_name}-gpu-node"
        Project: "InferOps"
  YAML

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "gpu_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: gpu-inference
    spec:
      template:
        metadata:
          labels:
            workload: gpu-inference
        spec:
          nodeClassRef:
            name: gpu-inference
          requirements:
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ${jsonencode(var.gpu_instance_types)}
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
          taints:
            - key: nvidia.com/gpu
              effect: NoSchedule
      limits:
        cpu: "40"
        memory: 160Gi
        nvidia.com/gpu: "10"
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 60s
  YAML

  depends_on = [helm_release.karpenter]
}
