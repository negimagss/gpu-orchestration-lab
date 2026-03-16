# Infra Ops — Financial AI Platform (MLOps + RAG + Chat)

> Industry-grade ML platform for financial document analysis. Scrapes SEC filings, ingests into a RAG pipeline, and serves a chatbot that answers questions about company financials with precision — deployed on production-grade AWS infrastructure.

---

## Architecture Overview

```
                    Platform Team (EKS - us-east-2)
                    ┌───────────────────────────────────────┐
                    │  vLLM (Qwen 2.5 1.5B) — 2 replicas   │
                    │  Qdrant (Vector DB)                   │
                    │  Airflow (Orchestration)               │
                    │  OTel Collector + Jaeger (Tracing)     │
                    │  Karpenter + HPA (Autoscaling)         │
                    └──────────────┬────────────────────────┘
                                   │
                          ALB (internal) + SQS
                                   │
                    Product Team (EC2 - us-east-2)
                    ┌──────────────┴────────────────────────┐
                    │  Go Chat App (:8080)                   │
                    │     ├── HTTP API + SSE streaming       │
                    │     └── localhost:8000 ──┐             │
                    │                          ▼             │
                    │  Python RAG Service (:8000)            │
                    │     ├── FastAPI                        │
                    │     ├── LangChain (RAG logic)          │
                    │     ├── Calls vLLM on EKS (inference)  │
                    │     ├── Calls Qdrant on EKS (retrieval)│
                    │     └── OTel instrumented              │
                    └────────────────────────────────────────┘
                                   │
                            ALB (public)
                                   │
                                Browser
```

---

## Use Case — Financial Document Q&A

- Scrape SEC EDGAR for 10-K / 10-Q filings (Apple, Tesla, etc.)
- Ingest, chunk, embed, and store in Qdrant via Airflow DAGs
- User asks: "What were Apple's main risk factors in their latest 10-K?"
- RAG retrieves relevant chunks → Qwen generates a grounded answer
- Evals measure precision, recall, faithfulness, and latency

---

## Tech Stack

| Component | Technology | Where |
|---|---|---|
| Model | Qwen 2.5 1.5B | EKS (GPU nodes) |
| Model Serving | vLLM (2 replicas) | EKS |
| Autoscaling | Karpenter (GPU nodes) + HPA (pods) | EKS |
| Vector DB | Qdrant | EKS |
| Orchestration | Airflow | EKS |
| Observability | OpenTelemetry + Jaeger | EKS |
| Chat App | Go (net/http + SSE) | EC2 |
| RAG Service | Python + FastAPI + LangChain | EC2 |
| Data Source | SEC EDGAR (free, public) | Scraped via Airflow |
| Evals | RAGAS + custom latency benchmarks | EC2 / Airflow |
| IaC | Terraform | Local |
| Container Registry | ECR | AWS |
| Async Queue | SQS | AWS |
| Load Balancer | ALB (public for app, internal for EKS) | AWS |
| Region | us-east-2 (Ohio) | AWS |
| GPU Instance | g5.xlarge (NVIDIA A10G, 24GB VRAM) | EKS |

---

## Team Separation (Enterprise Pattern)

### Platform Team — owns EKS cluster
- Manages GPU node pools, autoscaling, model serving
- Runs Qdrant, Airflow, Jaeger as platform services
- Exposes vLLM + Qdrant via internal ALB
- Monitors infra health, GPU utilization, node scaling

### Product Team — owns EC2 application
- Builds the chatbot (Go app + Python RAG service)
- Owns RAG logic, prompt engineering, evals
- Talks to EKS services via internal ALB / SQS
- Owns user-facing features and quality metrics

---

## Core Components

### 1. Infrastructure (AWS + Karpenter)
- EKS cluster in us-east-2 with Karpenter for GPU/CPU node autoscaling
- g5.xlarge spot instances for inference (NVIDIA A10G, 24GB VRAM)
- S3 for model artifacts, SEC filings, eval datasets
- ECR for container images
- SQS for async communication between EC2 and EKS

### 2. Model Serving (vLLM)
- Qwen 2.5 1.5B deployed on EKS via vLLM
- 2 replicas behind K8s Service (round-robin load balancing)
- HPA scales replicas based on request queue depth
- Karpenter provisions GPU nodes on-demand
- Continuous batching — handles concurrent requests per replica
- Exposed via internal ALB to EC2

### 3. Orchestration (Airflow)
- **DAG 1: SEC Scraper** — scrape EDGAR on schedule → download 10-K/10-Q PDFs → store in S3
- **DAG 2: Ingestion** — parse PDFs → chunk text → generate embeddings via LangChain → load into Qdrant
- **DAG 3: Eval Runner** — run RAGAS evals after new data ingestion → log scores

### 4. RAG Pipeline (LangChain + Qdrant)
- LangChain handles: document chunking → embedding generation → Qdrant storage → retrieval
- Python FastAPI service on EC2 exposes RAG as an API
- At query time: retrieve top-K chunks from Qdrant → build prompt → send to vLLM → stream response
- LangSmith tracing for debugging retrieval + generation quality

### 5. Observability (OpenTelemetry + Jaeger)
- OTel SDK instrumented in Go app + Python RAG service
- OTel Collector on EKS aggregates traces
- Jaeger UI for distributed trace visualization
- End-to-end traces: `user query → Go app → Python RAG → Qdrant retrieval → vLLM inference → SSE response`
- Metrics: request latency, token/s, TTFT, GPU utilization, replica count, queue depth

### 6. Evals & Testing

#### RAG Quality (RAGAS)
- Context Precision — did retrieval pull the right chunks?
- Context Recall — did it miss relevant chunks?
- Faithfulness — is the answer grounded in context or hallucinating?
- Answer Relevancy — does the answer address the question?
- Eval dataset: 25-30 Q&A pairs from Apple/Tesla 10-K filings

#### Performance / Latency
- Load testing with K6 or custom Go load tester
- Measure P50, P95, P99 latency at varying request rates (1, 10, 50 rps)
- Track TTFT (time to first token), total generation time, tokens/s
- Observe HPA and Karpenter scaling behavior under load

#### End-to-End System Tests
- Health checks — all pods running?
- Inference smoke test — send query, get response?
- RAG test — retrieval returns relevant docs?
- Streaming test — SSE streams tokens correctly?
- Failover test — kill a pod, does other replica handle it?
- Scaling test — spike load, does Karpenter provision new node?

### 7. Chat App (Go on EC2)
- Go binary serving HTTP on :8080
- SSE endpoint for streaming LLM responses to browser
- Forwards queries to Python RAG service on localhost:8000
- Simple frontend — Go templates + vanilla JS
- Public-facing via ALB

---

## Build Phases

| Phase | What | Key Outcome | Time Estimate |
|---|---|---|---|
| 0 | Write all code locally (Terraform, Go, Python, Helm, DAGs) | Everything ready to deploy | Pre-weekend |
| 1 | `terraform apply` — EKS + Karpenter + networking | Cluster up in us-east-2 | 20 min |
| 2 | Deploy vLLM (2 replicas) + Qdrant via Helm | Model serving + vector DB running | 30 min |
| 3 | Deploy Airflow, run scraper + ingestion DAG | SEC data in Qdrant | 45 min |
| 4 | Deploy Go app + Python RAG service on EC2 | Chatbot working end-to-end | 30 min |
| 5 | Deploy OTel + Jaeger, verify traces | Full observability | 20 min |
| 6 | Run RAGAS evals + load tests | Quality + performance validated | 45 min |
| 7 | Demo, screenshots, recording | Portfolio proof | 30 min |
| 8 | `terraform destroy` | $0 ongoing cost | 5 min |

---

## Cost Estimate (4-6 hours runtime)

| Resource | Cost/hr | Hours | Total |
|---|---|---|---|
| EKS control plane | $0.10/hr | 6 | $0.60 |
| 2x g5.xlarge (spot, A10G) | ~$0.50/hr each | 6 | ~$6.00 |
| EC2 t3.medium (Go + Python) | $0.04/hr | 6 | $0.24 |
| ALB | $0.02/hr | 6 | $0.12 |
| SQS, S3, ECR | negligible | - | ~$0.50 |
| **Total** | | | **~$8-10** |

Using spot instances keeps GPU cost low. Worst case with on-demand: ~$15-20.

---

## Key Design Decisions

- **Why separate EC2 and EKS?** — Mirrors real enterprise pattern. Platform team owns the cluster, product team owns the app. Clean separation of concerns.
- **Why SQS between app and inference?** — Decouples frontend from backend. Handles bursts, retries, lets inference scale independently.
- **Why SSE over WebSockets?** — Simpler for unidirectional streaming (LLM → browser). Native browser support.
- **Why Go for the chat app?** — Single binary, low resource usage, excellent concurrency for SSE connections.
- **Why Python for RAG?** — LangChain ecosystem, RAGAS evals, LangSmith tracing. ML tooling is Python-first.
- **Why vLLM over TGI?** — Better continuous batching, PagedAttention, higher throughput for concurrent users.
- **Why Karpenter over Cluster Autoscaler?** — Faster node provisioning, better GPU instance selection, more flexible.
- **Why OpenTelemetry over Prometheus+Grafana?** — Industry standard for distributed tracing. Better for end-to-end request flow visibility across services.
- **Why self-hosted over managed?** — Learning exercise. Understanding every layer from GPU scheduling to token streaming.

---

## Status

- [x] Plan defined
- [x] Architecture finalized
- [ ] Phase 0: Write all code locally
- [ ] Phase 1: Infrastructure (EKS + Karpenter)
- [ ] Phase 2: Model Serving (vLLM + Qdrant)
- [ ] Phase 3: Orchestration (Airflow + DAGs)
- [ ] Phase 4: Application (Go + Python on EC2)
- [ ] Phase 5: Observability (OTel + Jaeger)
- [ ] Phase 6: Evals + Load Testing
- [ ] Phase 7: Demo + Documentation
- [ ] Phase 8: Teardown
