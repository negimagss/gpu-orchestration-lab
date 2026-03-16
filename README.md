# Infra Ops — Learning Scalable AI/ML Infrastructure

A hands-on project for learning how to build production-grade infrastructure for AI/ML workloads on AWS. The focus is on the infrastructure layer — GPU scheduling, Kubernetes orchestration, autoscaling, observability, and IaC — not on the model or ML research itself.

The workload is a RAG chatbot over SEC financial filings, chosen because it exercises every layer of the stack: GPU inference, vector search, streaming, distributed tracing, and multi-service networking.

```
Browser → Go Chat App → Python RAG Service → Qdrant (vector search) → vLLM (GPU inference)
         [EC2 - Product Team]                 [EKS - Platform Team]
```

---

## Why This Project Exists

This is a learning platform, not a product. The goal is to get hands-on experience with the infrastructure patterns that companies use to serve AI/ML at scale:

- **How do you schedule GPU workloads on Kubernetes?** (Karpenter, NVIDIA device plugin, tolerations/taints)
- **How does Karpenter differ from Cluster Autoscaler?** (90s provisioning vs 3-5 min, spot-aware, scale-to-zero)
- **How do you serve LLMs in production?** (vLLM, continuous batching, PagedAttention, OpenAI-compatible API)
- **How do you stream LLM responses?** (SSE from vLLM → Python → Go → browser, with connection management)
- **How do you observe distributed AI systems?** (OpenTelemetry traces across Go + Python, Jaeger visualization)
- **How do you manage the full lifecycle with IaC?** (Terraform up in 20 min, tear down in 5 min, ephemeral by design)
- **How do real companies separate platform and product teams?** (EKS owns infra, EC2 owns the app — clean API boundaries)

The financial chatbot is just the vehicle — what matters is everything underneath it.

---

## What the Demo Does

1. **Scrapes SEC EDGAR** for 10-K annual filings (Apple, Tesla, Microsoft, Google, Amazon)
2. **Chunks and embeds** filing text into 4741 vectors using `all-MiniLM-L6-v2`
3. **Stores vectors** in Qdrant for similarity search (~2ms per query)
4. **Serves a chatbot** where users ask financial questions in natural language
5. **Retrieves relevant context** via RAG and generates answers using self-hosted Qwen 2.5 1.5B on GPU
6. **Streams responses** token-by-token to the browser via SSE

---

## Architecture

```
                    EKS Cluster (us-east-2)
                    ┌─────────────────────────────────────────────┐
                    │                                             │
                    │  [inference namespace]                      │
                    │    vLLM × 2 replicas (Qwen 2.5 1.5B)       │
                    │      └─ g5.xlarge spot (NVIDIA A10G 24GB)   │
                    │    Qdrant (vector DB, 4741 vectors)         │
                    │                                             │
                    │  [data namespace]                           │
                    │    SEC Scraper Job (completed)               │
                    │    Qdrant Ingestion Job (completed)          │
                    │                                             │
                    │  [observability namespace]                  │
                    │    Jaeger (distributed tracing)              │
                    │    OTel Collector (trace aggregation)        │
                    │                                             │
                    │  [kube-system]                              │
                    │    Karpenter (GPU node autoscaler)           │
                    │    NVIDIA Device Plugin                     │
                    │    CoreDNS, EBS CSI, kube-proxy             │
                    └──────────────┬──────────────────────────────┘
                                   │ NodePort
                                   │
                    EC2 App Server (t3.medium)
                    ┌──────────────┴──────────────────────────────┐
                    │  Go Chat App (:8080)                         │
                    │    ├── Serves web UI (Go templates + JS)     │
                    │    ├── SSE streaming to browser              │
                    │    └── Forwards queries to RAG service       │
                    │                                             │
                    │  Python RAG Service (:8000)                  │
                    │    ├── FastAPI + LangChain                   │
                    │    ├── Embeds query → searches Qdrant        │
                    │    ├── Builds prompt with SEC context        │
                    │    ├── Calls vLLM for generation             │
                    │    └── OTel instrumented                    │
                    └──────────────┬──────────────────────────────┘
                                   │
                            ALB (public, internet-facing)
                                   │
                                Browser
```

---

## Tech Stack

| Layer | Technology | Purpose |
|---|---|---|
| **LLM** | Qwen 2.5 1.5B Instruct | Financial Q&A generation |
| **Model Serving** | vLLM v0.4.1 | OpenAI-compatible API, continuous batching, PagedAttention |
| **GPU** | NVIDIA A10G (24GB VRAM) on g5.xlarge | LLM inference at 58-97 tokens/s |
| **GPU Autoscaling** | Karpenter | Provisions/terminates spot GPU nodes in ~90s |
| **Vector DB** | Qdrant | Stores and searches SEC filing embeddings |
| **Embeddings** | all-MiniLM-L6-v2 (384-dim) | Encodes queries and document chunks |
| **RAG Framework** | LangChain | Document chunking, retrieval, prompt construction |
| **Chat App** | Go (net/http + SSE) | Web UI, streaming responses |
| **RAG Service** | Python + FastAPI | RAG pipeline API |
| **Tracing** | OpenTelemetry + Jaeger | End-to-end distributed tracing |
| **Infrastructure** | Terraform | EKS, VPC, ALB, EC2, ECR, SQS, S3 |
| **Container Registry** | Amazon ECR | Docker image storage |
| **Orchestration** | Kubernetes (EKS v1.29) | Pod scheduling, service discovery |
| **Helm** | Helm charts | Deployment packaging for vLLM, Qdrant, Jaeger, OTel |
| **Data Source** | SEC EDGAR | Public 10-K filings (free API) |

---

## Project Structure

```
InferOps/
├── app/
│   ├── chat/              # Go chat app (web UI + SSE streaming)
│   │   ├── main.go
│   │   ├── handlers/
│   │   ├── sse/
│   │   └── templates/
│   └── rag/               # Python RAG service (FastAPI + LangChain)
│       ├── main.py
│       ├── config/
│       └── rag/
├── dags/                   # Airflow DAGs (scraper, ingestion, evals)
│   ├── sec_scraper_dag.py
│   ├── ingestion_dag.py
│   └── eval_runner_dag.py
├── db/
│   └── migrations/
├── docker/
│   ├── chat-app/           # Dockerfile — multi-stage Go build
│   ├── rag-service/        # Dockerfile — Python + ML deps
│   ├── airflow/            # Dockerfile — Airflow with baked-in DAGs
│   └── vllm/               # Dockerfile — vLLM custom config
├── evals/
│   ├── datasets/           # RAGAS eval Q&A pairs
│   └── loadtest/           # K6 load test scripts
├── helm/
│   ├── vllm/               # Helm chart — vLLM deployment
│   ├── qdrant/             # Helm chart — Qdrant StatefulSet
│   ├── airflow/            # Helm chart — Airflow
│   ├── jaeger/             # Helm chart — Jaeger
│   └── otel-collector/     # Helm chart — OTel Collector
├── infra/
│   ├── vpc.tf              # VPC, subnets, NAT gateway
│   ├── eks.tf              # EKS cluster + managed node group
│   ├── karpenter.tf        # Karpenter NodePool for GPU nodes
│   ├── ec2.tf              # App server EC2 instance
│   ├── ecr.tf              # ECR repositories (4 images)
│   ├── alb.tf              # Public ALB → EC2
│   ├── s3.tf               # Data bucket for SEC filings
│   ├── sqs.tf              # Inference request queue
│   ├── variables.tf
│   ├── providers.tf
│   ├── outputs.tf
│   └── templates/
│       └── ec2_userdata.sh
├── scripts/
│   ├── build-push-ecr.sh   # Build all Docker images and push to ECR
│   └── deploy.sh           # Full deploy script (terraform → helm → verify)
├── docker-compose.yml      # Local development compose
├── k8s-pod-structure.md    # Live pod/node documentation + cost analysis
└── PLAN.md                 # Original build plan and phases
```

---

## Infrastructure Skills Covered

### 1. GPU Scheduling on Kubernetes
Deploy GPU workloads with NVIDIA device plugin, node taints/tolerations, and resource limits. Understand how K8s schedules pods onto GPU nodes and how to isolate GPU from CPU workloads using namespaces and node selectors.

### 2. Karpenter for GPU Autoscaling
Use Karpenter (not Cluster Autoscaler) for GPU node management — the industry is moving to Karpenter for good reasons:
- Provisions g5.xlarge spot instances (~50% cheaper than on-demand)
- Scales to zero when no inference workload (GPU nodes terminate automatically)
- Provisions nodes in ~90 seconds vs 3-5 minutes with Cluster Autoscaler
- Selects from a pool of instance types based on spot availability and price

### 3. Self-Hosted LLM Serving with vLLM
Deploy an open-source LLM on your own GPU infrastructure using vLLM. Learn continuous batching, PagedAttention, OpenAI-compatible APIs, and why vLLM is the standard for production inference. Compare self-hosted costs vs Bedrock/SageMaker.

### 4. Multi-Service Networking (EKS ↔ EC2)
Build cross-boundary networking between EKS and EC2 using NodePort services, security groups, and service discovery. Understand the tradeoffs vs ALB/NLB with AWS Load Balancer Controller.

### 5. Real-Time Streaming Architecture
Stream LLM responses token-by-token using SSE across 3 services (vLLM → Python → Go → browser). Learn about connection lifecycle, reconnection handling, and the race conditions that come with persistent connections.

### 6. Distributed Tracing with OpenTelemetry
Instrument Go and Python services with OTel SDK. Traces flow across language boundaries (Go → Python → external services). Visualize in Jaeger to see where time is spent (retrieval vs generation vs network).

### 7. Infrastructure as Code (Terraform)
Every resource defined in Terraform — one `terraform apply` creates the entire platform, one `terraform destroy` tears it all down. EKS, VPC, Karpenter, EC2, ECR, S3 — no manual AWS console work. Designed for ephemeral deployment.

### 8. Enterprise Team Separation Pattern
Separate infrastructure into two teams mirroring real companies:
- **Platform Team** owns EKS — GPU nodes, model serving, vector DB, observability
- **Product Team** owns EC2 — chat app, RAG logic, user experience

This forces clean API boundaries and realistic deployment patterns.

---

## Deployment

### Prerequisites
- AWS CLI configured with appropriate permissions
- Terraform >= 1.5.0
- kubectl
- Helm
- Docker

### Quick Deploy
```bash
# Full deploy (terraform + images + helm + verify)
bash scripts/deploy.sh

# Or step by step:
cd infra && terraform apply -auto-approve && cd ..
bash scripts/build-push-ecr.sh
aws eks update-kubeconfig --region us-east-2 --name inferops-eks
# Helm installs happen in deploy.sh
```

### Teardown
```bash
cd infra && terraform destroy -auto-approve
```

---

## Performance (Observed)

| Metric | Value |
|---|---|
| LLM throughput | 58-97 tokens/s |
| Prompt processing | 100-260 tokens/s |
| Vector search latency | ~2ms (Qdrant) |
| RAG retrieval (embed + search) | ~20-27ms |
| End-to-end query time | 0.2-0.8s (depending on response length) |
| GPU memory utilization | 90% (configured) |
| Concurrent SSE clients | 3+ tested |

---

## Cost (Actual)

| Resource | Cost/hr |
|---|---|
| EKS control plane | $0.10 |
| 2x g5.xlarge spot (GPU) | ~$1.00 |
| 2x t3.large (CPU nodes) | $0.17 |
| EC2 t3.medium (app server) | $0.04 |
| NAT Gateway | $0.045 |
| ALB | $0.023 |
| **Total (active)** | **~$1.38/hr (~$33/day)** |
| **Total (idle, GPU nodes terminated)** | **~$0.38/hr (~$9/day)** |

Designed to be spun up for testing and torn down same day. Karpenter scale-to-zero ensures GPU costs stop when inference stops.

---

## Data

10 SEC 10-K filings stored in S3 and embedded in Qdrant:

| Company | Filings |
|---|---|
| Apple (AAPL) | 2024, 2025 |
| Tesla (TSLA) | 2025, 2026 |
| Microsoft (MSFT) | 2024, 2025 |
| Alphabet/Google (GOOGL) | 2025, 2026 |
| Amazon (AMZN) | 2025, 2026 |

Total: 4741 embedding vectors (384-dim, all-MiniLM-L6-v2)

---

## Key Design Decisions

| Decision | Why |
|---|---|
| **Self-hosted vLLM over Bedrock/SageMaker** | Full control, data stays in VPC, learn the GPU infra stack |
| **Karpenter over Cluster Autoscaler** | 3x faster GPU provisioning, spot support, scale-to-zero |
| **Separate EC2 + EKS** | Mirrors enterprise team separation (platform vs product) |
| **Go for chat app** | Single binary, low memory, excellent SSE/concurrency |
| **Python for RAG** | LangChain, sentence-transformers, RAGAS evals — ML ecosystem is Python-first |
| **SSE over WebSockets** | Simpler for unidirectional LLM streaming, native browser support |
| **vLLM over TGI** | Better continuous batching, PagedAttention, higher concurrent throughput |
| **OpenTelemetry over Prometheus** | Industry standard for distributed tracing across services |
| **Spot instances for GPU** | 50% cost reduction, acceptable for stateless inference workloads |
| **Terraform for everything** | One command up, one command down — ephemeral by design |
