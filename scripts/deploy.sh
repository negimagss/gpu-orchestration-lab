#!/bin/bash
set -euo pipefail

# ── Full deploy script — run on deploy day ───────
# Prerequisites:
#   - AWS CLI configured
#   - Terraform installed
#   - kubectl installed
#   - Helm installed
#   - Docker running
#   - GPU quota approved for g5.xlarge in us-east-2

AWS_REGION="${AWS_REGION:-us-east-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
PROJECT="inferops"

echo "╔══════════════════════════════════════╗"
echo "║     InferOps — Deploy Day            ║"
echo "╚══════════════════════════════════════╝"

# ── Step 1: Terraform Apply ──────────────────────
echo ""
echo "=== Step 1/6: Terraform Apply ==="
cd infra
terraform init
terraform apply -auto-approve
cd ..

# ── Step 2: Update kubeconfig ────────────────────
echo ""
echo "=== Step 2/6: Configure kubectl ==="
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${PROJECT}-eks"
kubectl get nodes

# ── Step 3: Build and Push to ECR ────────────────
echo ""
echo "=== Step 3/6: Build & Push Images ==="
bash scripts/build-push-ecr.sh

# ── Step 4: Deploy Helm Charts ───────────────────
echo ""
echo "=== Step 4/6: Deploy Helm Charts ==="

# Create namespaces
kubectl create namespace inference --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# Deploy vLLM
echo "Deploying vLLM..."
helm upgrade --install vllm helm/vllm \
  --namespace inference \
  --set image.repository="${ECR_REGISTRY}/${PROJECT}/vllm" \
  --set image.tag=latest \
  --wait --timeout 10m

# Deploy Qdrant
echo "Deploying Qdrant..."
helm upgrade --install qdrant helm/qdrant \
  --namespace data \
  --wait --timeout 5m

# Deploy Airflow
echo "Deploying Airflow..."
helm upgrade --install airflow helm/airflow \
  --namespace data \
  --set image.repository="${ECR_REGISTRY}/${PROJECT}/airflow" \
  --set image.tag=latest \
  --wait --timeout 5m

# Deploy Jaeger
echo "Deploying Jaeger..."
helm upgrade --install jaeger helm/jaeger \
  --namespace observability \
  --wait --timeout 5m

# Deploy OTel Collector
echo "Deploying OTel Collector..."
helm upgrade --install otel-collector helm/otel-collector \
  --namespace observability \
  --wait --timeout 5m

# ── Step 5: Verify ───────────────────────────────
echo ""
echo "=== Step 5/6: Verify Deployment ==="
echo "--- Pods ---"
kubectl get pods -A
echo ""
echo "--- Services ---"
kubectl get svc -A
echo ""
echo "--- GPU Nodes ---"
kubectl get nodes -l workload=gpu-inference

# ── Step 6: Output URLs ─────────────────────────
echo ""
echo "=== Step 6/6: Access URLs ==="
ALB_DNS=$(terraform -chdir=infra output -raw alb_public_dns)
echo "Chatbot URL:    ${ALB_DNS}"
echo "Jaeger UI:      kubectl port-forward -n observability svc/jaeger 16686:16686"
echo "Airflow UI:     kubectl port-forward -n data svc/airflow-webserver 8081:8080"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     Deploy Complete!                 ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "To teardown: cd infra && terraform destroy -auto-approve"
