# ── Outputs ──────────────────────────────────────

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_update_kubeconfig" {
  description = "Command to update kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_repositories" {
  description = "ECR repository URLs"
  value = {
    chat_app    = aws_ecr_repository.chat_app.repository_url
    rag_service = aws_ecr_repository.rag_service.repository_url
    vllm        = aws_ecr_repository.vllm.repository_url
    airflow     = aws_ecr_repository.airflow.repository_url
  }
}

output "sqs_inference_queue_url" {
  description = "SQS inference request queue URL"
  value       = aws_sqs_queue.inference_requests.url
}

output "sqs_ingestion_queue_url" {
  description = "SQS ingestion trigger queue URL"
  value       = aws_sqs_queue.ingestion_triggers.url
}

output "s3_data_bucket" {
  description = "S3 bucket for data storage"
  value       = aws_s3_bucket.data.id
}

output "app_server_public_ip" {
  description = "EC2 app server public IP"
  value       = aws_instance.app_server.public_ip
}

output "alb_public_dns" {
  description = "Public ALB DNS name — this is your chatbot URL"
  value       = "http://${aws_lb.public.dns_name}"
}

output "app_server_id" {
  description = "EC2 app server instance ID (for SSM)"
  value       = aws_instance.app_server.id
}
