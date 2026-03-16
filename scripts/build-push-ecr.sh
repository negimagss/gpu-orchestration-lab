#!/bin/bash
set -euo pipefail

# ── Build and push all images to ECR ─────────────
# Run this before deploying to AWS

AWS_REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
PROJECT="inferops"

echo "=== ECR Registry: ${ECR_REGISTRY} ==="
echo "=== Region: ${AWS_REGION} ==="

# Login to ECR
echo "Logging into ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Build and push Chat App (Go)
echo "Building chat-app..."
docker build -t "${ECR_REGISTRY}/${PROJECT}/chat-app:latest" \
  -f docker/chat-app/Dockerfile app/chat/
docker push "${ECR_REGISTRY}/${PROJECT}/chat-app:latest"
echo "✓ chat-app pushed"

# Build and push RAG Service (Python)
echo "Building rag-service..."
docker build -t "${ECR_REGISTRY}/${PROJECT}/rag-service:latest" \
  -f docker/rag-service/Dockerfile app/rag/
docker push "${ECR_REGISTRY}/${PROJECT}/rag-service:latest"
echo "✓ rag-service pushed"

# Build and push Airflow (with DAGs baked in)
echo "Building airflow..."
docker build -t "${ECR_REGISTRY}/${PROJECT}/airflow:latest" \
  -f docker/airflow/Dockerfile .
docker push "${ECR_REGISTRY}/${PROJECT}/airflow:latest"
echo "✓ airflow pushed"

# Build and push vLLM (custom config)
echo "Building vllm..."
docker build -t "${ECR_REGISTRY}/${PROJECT}/vllm:latest" \
  -f docker/vllm/Dockerfile docker/vllm/
docker push "${ECR_REGISTRY}/${PROJECT}/vllm:latest"
echo "✓ vllm pushed"

echo ""
echo "=== All images pushed to ECR ==="
echo "Chat App:    ${ECR_REGISTRY}/${PROJECT}/chat-app:latest"
echo "RAG Service: ${ECR_REGISTRY}/${PROJECT}/rag-service:latest"
echo "Airflow:     ${ECR_REGISTRY}/${PROJECT}/airflow:latest"
echo "vLLM:        ${ECR_REGISTRY}/${PROJECT}/vllm:latest"
