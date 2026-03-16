# Week 1 — Infrastructure Up, End-to-End Demo Working

**Date**: March 15, 2026
**Goal**: Stand up the full InferOps platform from scratch and get a working chatbot demo over SEC filings.
**Status**: Done. Chatbot is live, infrastructure is running, traces are flowing.

---

## What We Built

### Infrastructure (Terraform)
- VPC with public/private subnets across 2 AZs in us-east-2
- EKS cluster (v1.29) with managed CPU node group (2x t3.medium)
- Karpenter controller + NodePool for GPU spot instances (g5.xlarge, NVIDIA A10G)
- EC2 app server (t3.medium) with Elastic IP for public access
- ECR repositories for all container images
- S3 bucket for SEC filing storage
- Security group rules for EKS ↔ EC2 cross-boundary networking via NodePort

### Platform Team (EKS)
- **vLLM** — 2 replicas serving Qwen2.5-1.5B-Instruct on GPU, 58-97 tok/s
- **Qdrant** — StatefulSet with 4741 vectors from 10 SEC filings (5 companies x 2 filings)
- **Jaeger** — Distributed tracing UI, collecting traces from all services
- **OTel Collector** — Aggregates OpenTelemetry spans, forwards to Jaeger
- **Karpenter** — Provisioned 2 GPU spot nodes in ~90 seconds
- **NVIDIA Device Plugin** — GPU resource scheduling on K8s

### Product Team (EC2)
- **Go Chat App** — Web UI with SSE streaming, serves on port 8080
- **Python RAG Service** — FastAPI + LangChain, embeds queries, searches Qdrant, calls vLLM

### Data Pipeline (K8s Jobs)
- **SEC Scraper Job** — Scraped 10-K filings for AAPL, TSLA, MSFT, GOOGL, AMZN → S3
- **Qdrant Ingestion Job** — Chunked (1000/200), embedded (all-MiniLM-L6-v2), ingested 4741 vectors

---

## Bugs Fixed (9 total)

| # | Bug | Root Cause | Fix |
|---|-----|-----------|-----|
| 1 | EC2 unreachable, no Docker | No public IP → userdata failed | Allocated Elastic IP, installed Docker via SSM |
| 2 | EKS services not accessible | No AWS LB Controller → NLBs never provisioned | Switched to NodePort + security group rules |
| 3 | RAG service ImportError | Wrong OTel class name (`BatchSpanExporter`) | Changed to `BatchSpanProcessor` |
| 4 | Ingestion pod evicted | pip install torch used 13GB ephemeral storage | Used rag-service ECR image (deps pre-baked) |
| 5 | Qdrant retriever error | LangChain expected `page_content`, data stored as `text` | Added `content_payload_key="text"` |
| 6 | Queries never completed | Go goroutine used HTTP request context (cancelled on return) | Changed to `context.Background()` |
| 7 | Tokens lost on SSE reconnect | Hub race condition — old unregister deleted new connection | Pointer comparison in unregister logic |
| 8 | Duplicate SSE connections | Browser auto-reconnect + manual reconnect stacked up | Close old EventSource before creating new one |
| 9 | Sources showed "Unknown" | LangChain Qdrant wrapper can't read flat payload metadata | Replaced with direct `qdrant_client.search()` |

---

## What's Running Right Now

| Service | URL | Status |
|---------|-----|--------|
| Chat App | http://3.149.90.160:8080 | Live |
| Jaeger UI | http://3.149.90.160:16686 | Live |
| Qdrant Dashboard | http://3.149.90.160:6333/dashboard | Live |

### EKS Nodes
- 2x t3.medium (CPU, managed node group)
- 2x g5.xlarge (GPU, Karpenter spot instances)

### Cost
- ~$1.38/hr active (mostly GPU spot instances)
- Total session spend: ~$8-10

---

## Key Learnings

1. **Karpenter provisions GPU nodes in ~90s** — Cluster Autoscaler takes 3-5 min. Karpenter's bin-packing and direct EC2 fleet API calls make it significantly faster.

2. **vLLM continuous batching is real** — Multiple concurrent requests get batched on-GPU. No queuing layer needed for moderate load.

3. **SSE has production edge cases** — Connection lifecycle management, race conditions on reconnect, and Go context cancellation are non-obvious. WebSockets might be simpler for bidirectional needs.

4. **Small models (1.5B) are fast but limited** — 60-97 tok/s is great, but vague queries get "I don't have that information." A 7B model would reason better but needs a larger GPU instance.

5. **Large Docker images kill velocity** — rag-service was 4.5GB, Airflow was 9.45GB. ECR pushes took 30+ minutes. Build on EC2 or CI/CD next time.

6. **LangChain abstractions leak** — The Qdrant wrapper silently drops metadata when the payload structure doesn't match expectations. Going direct with `qdrant_client` was cleaner and more debuggable.

7. **NodePort works but isn't production-ready** — Node IPs change on spot interruptions, no load balancing, manual security groups. AWS LB Controller is the right path.

---

## Week 2 Plan

### Must-Do
- [ ] **Airflow on EKS** — Deploy with official Docker Hub image (skip ECR push). Wire up existing DAGs for scheduled SEC scraping and ingestion
- [ ] **RAGAS Evals** — Run faithfulness, answer relevancy, context precision/recall against a golden Q&A dataset. Establish baseline quality metrics for the 1.5B model
- [ ] **K6 Load Testing** — Measure p50/p95/p99 latency, max concurrent queries, throughput ceiling with 2 GPU replicas

### Should-Do
- [ ] **HPA for vLLM** — Configure Horizontal Pod Autoscaler with custom metrics (pending requests, GPU utilization via DCGM exporter). Stress test to trigger auto-scaling and watch Karpenter provision new GPU nodes
- [ ] **Prometheus + Grafana** — Add metrics pipeline alongside tracing. Dashboards for token throughput, retrieval latency, GPU memory, pod health
- [ ] **CloudWatch Alarms** — Alert on high error rates, pod restarts, GPU node count changes

### Nice-to-Have
- [ ] **Better SEC parsing** — Strip XBRL tags, extract financial tables properly. Current chunks include raw structured data that the model can't use
- [ ] **AWS Load Balancer Controller** — Replace NodePort with proper ALB/NLB ingress, add HTTPS with ACM
- [ ] **Larger model** — Try Qwen 7B or Llama 3.1 8B on g5.2xlarge to compare reasoning quality
- [ ] **SQS decoupling** — Add async queue between chat app and RAG service for production-style architecture
