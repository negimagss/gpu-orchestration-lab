# Infra Ops — K8s Pod Structure (Live Snapshot: Mar 15, 2026)

## Cluster: inferops-eks (us-east-2, EKS v1.29)

---

## Nodes (4 total)

| Node | Type | Role | Provisioner | AZ |
|---|---|---|---|---|
| `ip-10-0-1-6` | t3.large (CPU) | EKS Managed — runs system pods, CoreDNS, Karpenter | EKS Managed Node Group | us-east-2a |
| `ip-10-0-2-49` | t3.large (CPU) | EKS Managed — runs system pods, Qdrant, Jaeger | EKS Managed Node Group | us-east-2b |
| `ip-10-0-1-31` | g5.xlarge (GPU) | GPU Inference — runs vLLM replica 1 | Karpenter (spot) | us-east-2a |
| `ip-10-0-1-242` | g5.xlarge (GPU) | GPU Inference — runs vLLM replica 2 | Karpenter (spot) | us-east-2a |

---

## Namespace: `inference` — Model Serving + Vector DB

| Pod | What It Does | Node | GPU |
|---|---|---|---|
| `vllm-59dbd49bf4-9c9zb` | **LLM Inference** — serves Qwen/Qwen2.5-1.5B-Instruct via OpenAI-compatible API on :8000. Receives prompts with RAG context, generates financial analysis responses. Continuous batching, 58-97 tok/s. | `ip-10-0-1-31` (g5.xlarge) | 1x NVIDIA A10G 24GB |
| `vllm-59dbd49bf4-mzb6r` | **LLM Inference (replica 2)** — same as above, load-balanced via K8s Service round-robin. Provides redundancy and doubles throughput. | `ip-10-0-1-242` (g5.xlarge) | 1x NVIDIA A10G 24GB |
| `qdrant-0` | **Vector Database** — stores 4741 embedding vectors (384-dim, all-MiniLM-L6-v2) from 10 SEC 10-K filings. Handles similarity search queries in ~2ms. Ports: 6333 (HTTP), 6334 (gRPC). | `ip-10-0-2-49` (t3.large) | None |

### Services
- `vllm` — NodePort :8000 → :31906 — LLM inference API
- `qdrant` — NodePort :6333 → :31768 — vector search API

---

## Namespace: `data` — Pipeline Jobs (batch, not long-running)

| Pod | What It Does | Status | Node |
|---|---|---|---|
| `sec-scraper-5mvnz` | **SEC EDGAR Scraper** — one-off K8s Job. Scraped 10-K filings for AAPL, TSLA, MSFT, GOOGL, AMZN (2 per company) from SEC EDGAR API. Uploaded 10 HTML filings to S3 (`inferops-data-918791104396/sec-filings/`). | Completed | `ip-10-0-1-6` |
| `qdrant-ingest-sk9t2` | **Embedding + Ingestion** — one-off K8s Job. Downloaded 10 filings from S3, parsed HTML, chunked text (1000 chars, 200 overlap), embedded with all-MiniLM-L6-v2, loaded 4741 vectors into Qdrant `sec_filings` collection. | Completed | `ip-10-0-1-6` |
| `qdrant-ingest-7vdxk` | **Failed ingestion attempt** — first try that errored due to disk space on GPU node. | Error | `ip-10-0-1-31` |

---

## Namespace: `observability` — Tracing

| Pod | What It Does | Node |
|---|---|---|
| `jaeger-6458fcb6fc-m86bs` | **Jaeger** — distributed tracing UI + collector. Stores traces from the RAG pipeline. Ports: 16686 (UI), 14250/14268 (collector), 4317/4318 (OTLP). | `ip-10-0-2-49` |
| `otel-collector-fb95b99b7-kq8xt` | **OpenTelemetry Collector** — receives OTLP traces/metrics from the Go chat-app and Python RAG service on EC2, forwards to Jaeger. Ports: 4317 (gRPC), 4318 (HTTP). | `ip-10-0-1-6` |

### Services
- `jaeger` — NodePort :16686 → :30910 — tracing UI
- `otel-collector` — NodePort :4317 → :31285 — OTLP receiver

---

## Namespace: `kube-system` — Cluster Infrastructure

| Pod(s) | What It Does |
|---|---|
| `karpenter-*` (2 replicas) | **GPU Node Autoscaler** — provisions/deprovisions g5.xlarge spot instances based on pending pod requests. Manages the `gpu-inference` NodePool. |
| `coredns-*` (2 replicas) | **DNS** — resolves K8s service names (e.g., `vllm.inference.svc.cluster.local`). |
| `aws-node-*` (4 pods, 1 per node) | **VPC CNI** — assigns pod IPs from VPC subnets, manages ENIs. |
| `kube-proxy-*` (4 pods, 1 per node) | **Network Proxy** — iptables rules for K8s Service routing. |
| `ebs-csi-controller-*` (2 replicas) | **EBS CSI Driver** — provisions persistent EBS volumes (used by Qdrant for vector storage). |
| `ebs-csi-node-*` (4 pods, 1 per node) | **EBS CSI Node Agent** — mounts EBS volumes on nodes. |
| `eks-pod-identity-agent-*` (4 pods) | **IAM Pod Identity** — maps K8s service accounts to AWS IAM roles. |
| `nvidia-device-plugin-*` (2 pods, GPU nodes only) | **NVIDIA Device Plugin** — exposes GPU resources to K8s scheduler so pods can request `nvidia.com/gpu`. |

---

## EC2 App Server (outside EKS)

| Container | What It Does | Port |
|---|---|---|
| `inferops-chat-app-1` | **Go Chat App** — serves the web UI, handles SSE streaming to browser, forwards queries to RAG service. Public-facing via ALB. | :8080 |
| `inferops-rag-service-1` | **Python RAG Service** — receives queries, embeds them with all-MiniLM-L6-v2, searches Qdrant for top-5 chunks, builds prompt with SEC filing context, calls vLLM for generation, streams response back. OTel instrumented. | :8000 |

**EC2 Instance**: `i-0b3b9b4f4659f64c6` (t3.medium, `3.149.90.160`)
**ALB URL**: `http://inferops-public-alb-633125780.us-east-2.elb.amazonaws.com`

---

## Request Flow

```
Browser
  → ALB (:80)
    → EC2 chat-app (:8080) [Go, SSE]
      → EC2 rag-service (:8000) [Python, FastAPI]
        → Qdrant (EKS :31768) [vector search, ~2ms]
        → vLLM (EKS :31906) [LLM inference, 58-97 tok/s]
      ← streamed response
    ← SSE stream
  ← rendered in browser
```

---

## What I Learned From This Build

### 1. Karpenter — GPU Node Autoscaling
- Karpenter replaces AWS Cluster Autoscaler for provisioning GPU nodes
- When a vLLM pod is pending (needs `nvidia.com/gpu`), Karpenter detects it and spins up a `g5.xlarge` spot instance in **~90 seconds** — Cluster Autoscaler takes 3-5 minutes
- When pods are removed, Karpenter consolidates and terminates idle GPU nodes automatically (no wasted spend)
- It selects from a pool of instance types — can fall back to `g5.2xlarge` or `g4dn.xlarge` if `g5.xlarge` spot capacity is unavailable
- NodePool + NodeClass = declarative GPU infrastructure. You define constraints (instance types, AZs, capacity type), Karpenter handles the rest

### 2. vLLM — Self-Hosted LLM Serving
- Continuous batching means multiple concurrent requests share the GPU efficiently (not one-at-a-time)
- PagedAttention manages GPU KV cache like virtual memory — no wasted VRAM
- OpenAI-compatible API — any client that works with OpenAI works with vLLM, zero code changes
- 2 replicas behind K8s Service = built-in load balancing + fault tolerance

### 3. Spot Instances for GPU
- Both g5.xlarge nodes ran as **spot instances** (~$0.50/hr vs $1.01/hr on-demand = ~50% savings)
- Risk: spot can be reclaimed with 2-min warning. Karpenter handles this by draining pods and provisioning a replacement
- For inference workloads (stateless), spot is ideal — no data loss on reclaim

### 4. End-to-End RAG Pipeline
- Embedding + vector search (Qdrant) adds only ~20-25ms to each request
- The bottleneck is LLM generation, not retrieval
- Small models (1.5B) are fast (58-97 tok/s) but give shorter, less detailed answers
- System prompt design matters — the "only answer from context" rule prevents hallucination but also limits response richness

---

## Cost Analysis: Karpenter + vLLM (Self-Hosted) vs AWS SageMaker Endpoints

### This Build: Karpenter + EKS + vLLM

| Component | Cost/hr | Notes |
|---|---|---|
| EKS Control Plane | $0.10 | Fixed cost |
| 2x g5.xlarge (spot) | ~$1.00 | $0.50/hr each, Karpenter auto-provisions |
| 2x t3.large (CPU nodes) | $0.17 | $0.0832/hr each |
| NAT Gateway | $0.045 | Plus data transfer |
| ALB | $0.023 | Plus LCU charges |
| EC2 t3.medium (app) | $0.04 | Chat app + RAG service |
| **Total** | **~$1.38/hr** | **~$33/day** |

Karpenter with spot: if no inference load → Karpenter terminates GPU nodes → **cost drops to ~$0.38/hr** (just CPU nodes + control plane).

### Alternative: AWS SageMaker Real-Time Endpoints

| Component | Cost/hr | Notes |
|---|---|---|
| SageMaker endpoint (ml.g5.xlarge) | $1.408 | On-demand only, no spot for real-time endpoints |
| 2 instances (for redundancy) | $2.816 | You pay even when idle |
| SageMaker inference cost | +$0.0001/req | Per-request charges on top |
| **Total (inference only)** | **~$2.82/hr** | **~$67/day** |

No spot pricing. No scale-to-zero. You pay $2.82/hr 24/7 even with zero traffic.

### Alternative: SageMaker Serverless Inference

| Aspect | Details |
|---|---|
| Cost | Pay per request — $0.0001/sec of compute |
| Cold start | 30-60 seconds (unusable for real-time chat) |
| GPU | Not supported for serverless — CPU only |
| **Verdict** | Not viable for GPU LLM inference |

### Alternative: Amazon Bedrock (Managed API)

| Aspect | Details |
|---|---|
| Cost | ~$0.0008/1K input tokens, ~$0.0024/1K output tokens (Claude Haiku tier) |
| At 1000 queries/day (avg 500 input + 100 output tokens) | ~$2.80/day |
| Pros | No infra, no GPUs, scales infinitely, zero ops |
| Cons | No custom models, vendor lock-in, no fine-tuning, limited model choice, data leaves your VPC |
| **Verdict** | Cheapest if you don't need self-hosted. But you lose control over the model. |

### Comparison Summary

| Approach | Cost/day (2 replicas) | Scale-to-Zero | Spot Pricing | Custom Models | Ops Burden |
|---|---|---|---|---|---|
| **Karpenter + vLLM (this build)** | ~$33 (active) / ~$9 (idle) | Yes (Karpenter) | Yes (50% savings) | Full control | High — you own everything |
| **SageMaker Real-Time** | ~$67 | No | No (real-time) | Yes (bring your own) | Medium — managed infra, but rigid |
| **SageMaker Serverless** | Pay-per-use | Yes | N/A | CPU only, no LLMs | Low |
| **Amazon Bedrock** | ~$2.80 (1K queries) | Yes (fully managed) | N/A | No (pre-built models only) | None |

### When to Use What

- **Karpenter + vLLM**: You need custom/fine-tuned models, want full control, have ML engineering capacity, need to optimize cost with spot. Best for teams that want to own the stack.
- **SageMaker Endpoints**: You want AWS-managed GPU infra but still bring your own model. Good middle ground but expensive without spot.
- **Bedrock**: You just need an LLM API and don't care about self-hosting. Cheapest for low-to-medium volume. No ops.

### Key Karpenter Advantages Over Cluster Autoscaler

| Feature | Karpenter | Cluster Autoscaler |
|---|---|---|
| Provisioning speed | ~90 seconds | 3-5 minutes |
| Instance selection | Flexible — picks best from pool | Fixed to node group instance type |
| Spot support | Native, with fallback | Requires separate node groups |
| Consolidation | Automatic — bins packs and removes underutilized nodes | Scales down only when node is empty |
| GPU awareness | First-class — understands GPU requests | Works but slower, less intelligent |
| Scale-to-zero | Yes — removes all Karpenter nodes when no pending pods | No — min size of node group is usually 1+ |
