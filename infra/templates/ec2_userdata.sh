#!/bin/bash
set -euo pipefail

# ── Install Docker ───────────────────────────────
dnf update -y
dnf install -y docker
systemctl enable docker
systemctl start docker

# ── Install Docker Compose ───────────────────────
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# ── Login to ECR ─────────────────────────────────
aws ecr get-login-password --region ${aws_region} | \
  docker login --username AWS --password-stdin ${ecr_registry}

# ── Pull images from ECR ─────────────────────────
docker pull ${ecr_registry}/${project_name}/chat-app:latest
docker pull ${ecr_registry}/${project_name}/rag-service:latest

# ── Write docker-compose.yml ─────────────────────
cat > /opt/inferops/docker-compose.yml <<'COMPOSE'
version: "3.8"
services:
  chat-app:
    image: ${ecr_registry}/${project_name}/chat-app:latest
    ports:
      - "8080:8080"
    environment:
      - RAG_SERVICE_URL=http://rag-service:8000
      - SQS_QUEUE_URL=${sqs_queue_url}
      - AWS_REGION=${aws_region}
    depends_on:
      - rag-service
    restart: unless-stopped

  rag-service:
    image: ${ecr_registry}/${project_name}/rag-service:latest
    ports:
      - "8000:8000"
    environment:
      - VLLM_BASE_URL=http://${eks_endpoint}:8000/v1
      - QDRANT_URL=http://${eks_endpoint}:6333
      - SQS_QUEUE_URL=${sqs_queue_url}
      - AWS_REGION=${aws_region}
      - OTEL_EXPORTER_OTLP_ENDPOINT=http://${eks_endpoint}:4317
    restart: unless-stopped
COMPOSE

# ── Create working directory ─────────────────────
mkdir -p /opt/inferops

# ── Start services ───────────────────────────────
cd /opt/inferops
docker-compose up -d
