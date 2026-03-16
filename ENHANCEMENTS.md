# Infra Ops — Enhancements, Deviations & Lessons Learned

This document captures what changed from the original PLAN.md during the initial build session,
why things broke, what was skipped, and what improvements were made to get the demo working.

---

## What Worked As Planned

- **Terraform + EKS**: Cluster provisioned with VPC, subnets, EKS managed node groups (t3.medium CPU nodes)
- **Karpenter GPU autoscaling**: NodePool with `g5.xlarge` spot instances provisioned 2 GPU nodes in ~90 seconds
- **vLLM on GPU**: 2 replicas of Qwen2.5-1.5B-Instruct serving at 58-97 tok/s on NVIDIA A10G GPUs
- **Qdrant vector DB**: StatefulSet with persistent storage, 4741 vectors ingested successfully
- **SEC EDGAR scraper**: K8s Job scraped 10 filings (2 per company: AAPL, TSLA, MSFT, GOOGL, AMZN)
- **Go Chat App + Python RAG Service**: Both built, containerized, pushed to ECR, deployed on EC2
- **SSE streaming**: Token-by-token streaming from vLLM → RAG service → chat app → browser
- **OpenTelemetry + Jaeger**: OTel Collector and Jaeger deployed for distributed tracing
- **Cost**: Stayed under $10 budget using spot instances

---

## Bugs Found & Fixed During Build

### 1. EC2 Instance Had No Public IP
- **Symptom**: Userdata script failed, SSM agent couldn't connect, Docker never installed
- **Root cause**: Terraform didn't assign a public IP to the EC2 instance
- **Fix**: Allocated an Elastic IP (3.149.90.160), associated it, rebooted. Then installed Docker manually via SSM

### 2. EKS Service Networking — No AWS Load Balancer Controller
- **Symptom**: Changed services to `type: LoadBalancer` but NLBs never provisioned
- **Root cause**: AWS Load Balancer Controller was not installed on the cluster
- **Fix**: Reverted to `NodePort` services. Added security group rules so EC2 could reach EKS nodes on port range 30000-32767. Services accessed via `<node-internal-ip>:<nodeport>`

### 3. OpenTelemetry Import Error in RAG Service
- **Symptom**: `ImportError: cannot import name 'BatchSpanExporter'`
- **Root cause**: Wrong class name — should be `BatchSpanProcessor`
- **Fix**: `app/rag/main.py` — changed `BatchSpanExporter` → `BatchSpanProcessor`

### 4. Qdrant Ingestion Pod Evicted (Ephemeral Storage)
- **Symptom**: First ingestion K8s Job evicted — node ran out of ephemeral storage
- **Root cause**: Used `python:3.11-slim` base image which pip-installed torch (~13GB) at runtime
- **Fix**: Used the rag-service ECR image (already has ML dependencies baked in) as the Job's container image

### 5. Qdrant Retriever — Missing Content Payload Key
- **Symptom**: `page_content none is not allowed` error from LangChain
- **Root cause**: Ingestion stored text under `"text"` key but LangChain Qdrant wrapper defaults to `"page_content"`
- **Fix**: `app/rag/rag/retriever.py` — added `content_payload_key="text"` to Qdrant vectorstore init

### 6. Go Context Cancellation — Queries Never Completed
- **Symptom**: Browser sent query, got "processing" response, but never received streaming tokens
- **Root cause**: `forwardToRAG()` goroutine used `r.Context()` from the HTTP request. When the `Chat` handler returned the JSON response, the request context was cancelled, killing the in-flight RAG request
- **Fix**: `app/chat/handlers/handlers.go` — changed `go h.forwardToRAG(ctx, req)` to `go h.forwardToRAG(context.Background(), req)`. This is a classic Go pattern — background goroutines must not use the parent HTTP request's context

### 7. SSE Hub Race Condition — Tokens Lost on Reconnect
- **Symptom**: Queries intermittently returned no response; browser showed "Reconnecting..."
- **Root cause**: When the browser's EventSource reconnected with the same client ID, the new connection replaced the old one in the hub map. Then the old connection's deferred `Unregister` ran and deleted the NEW connection (it checked by ID string, not by pointer). Tokens sent after this point were silently dropped
- **Fix**: `app/chat/sse/hub.go` — changed unregister logic to compare pointers: `if existing, ok := h.clients[client.ID]; ok && existing == client { ... }`. Old connections can no longer accidentally delete newer ones

### 8. SSE Client Duplicate Connections
- **Symptom**: Multiple SSE connections stacking up per browser tab
- **Root cause**: Browser's native EventSource auto-reconnects on error, AND our `onerror` handler also created a new EventSource without closing the old one
- **Fix**: `app/chat/templates/index.html` — close existing EventSource before creating a new one in `connectSSE()`, and explicitly close before manual reconnect in `onerror`

### 9. Retriever Metadata Not Returned — "Unknown - Filing - Page N/A"
- **Symptom**: All sources showed "Unknown - Filing - Page N/A" instead of company names
- **Root cause**: LangChain's Qdrant wrapper expects metadata nested under a `"metadata"` payload key, but our ingestion stored fields flat at the top level (`company`, `filing_type`, etc.)
- **Fix**: `app/rag/rag/retriever.py` — replaced LangChain's retriever with direct `qdrant_client.search()` calls, manually extracting metadata from the flat payload. Also updated `app/rag/rag/generator.py` to show `filing_date` instead of `page` (our data has dates, not page numbers)

---

## What Was Skipped (and Why)

### 1. Airflow Deployment
- **Original plan**: Airflow on EKS orchestrates SEC scraping and Qdrant ingestion DAGs
- **Why skipped**: The Airflow Docker image was 9.45GB and ECR push was taking forever on slow upload. The image push alone was estimated at 2+ hours
- **What we did instead**: Ran SEC scraping and Qdrant ingestion as one-off K8s Jobs. Same result, much faster for a demo
- **Next steps**: Deploy Airflow properly with the official `apache/airflow:2.8.1` image from Docker Hub (no ECR push needed). Wire up the existing DAGs in `dags/`

### 2. RAGAS Evaluation Suite
- **Original plan**: Run RAGAS evals (faithfulness, answer relevancy, context precision/recall) with a golden dataset
- **Why skipped**: Time constraint — user wanted to test the demo first
- **Next steps**: The eval framework exists in `evals/`. Run it against the live RAG pipeline to measure quality. The small 1.5B model will likely score lower on faithfulness than a larger model

### 3. K6 Load/Stress Testing
- **Original plan**: Run K6 load tests to measure throughput, latency percentiles, and find breaking points
- **Why skipped**: Time constraint — same as evals
- **Next steps**: K6 scripts should target the `/api/chat` endpoint with concurrent users. Measure p50/p95/p99 latency and max concurrent queries before degradation

### 4. SQS Decoupling
- **Original plan**: SQS queue between chat app and RAG service for async processing and scale-to-zero
- **Why skipped**: Direct HTTP + SSE streaming was simpler and sufficient for the demo. SQS would add complexity without clear benefit at this scale
- **Next steps**: Add SQS if you need to decouple the frontend from inference for production use (e.g., queue management, retries, scale-to-zero)

### 5. ALB (Application Load Balancer)
- **Original plan**: ALB in front of EC2 for HTTPS termination and routing
- **Why skipped**: No AWS Load Balancer Controller on EKS, and for a demo, direct EC2 public IP + port 8080 was sufficient
- **Next steps**: Install AWS Load Balancer Controller, create Ingress resources, add ACM certificate for HTTPS

### 6. HPA (Horizontal Pod Autoscaler) for vLLM
- **Original plan**: HPA scales vLLM replicas based on GPU utilization or request queue depth
- **Why skipped**: 2 static replicas were sufficient for demo load
- **Next steps**: Configure HPA with custom metrics from DCGM exporter (GPU utilization) or Prometheus (request queue length)

---

## Key Architectural Lessons

### 1. Small Models Are Fast But Limited
Qwen2.5-1.5B generates at 58-97 tok/s but struggles with:
- Vague queries ("is Tesla doing good?") — defaults to "I don't have that information"
- Cross-company comparisons — needs more reasoning capability
- Synthesizing from XBRL-heavy context — can't extract meaning from structured data tags

A 7B or 70B model would handle these better but requires more GPU memory / larger instances.

### 2. SEC Filing Data Quality Matters
Raw HTML from SEC EDGAR includes XBRL tags, segment identifiers, and structured data that isn't human-readable. Some chunks ingested into Qdrant contain content like `us-gaap:OperatingSegmentsMember` instead of actual financial text. Better HTML parsing (stripping XBRL, extracting tables properly) would significantly improve RAG quality.

### 3. SSE Is Tricky in Production
Server-Sent Events work great for streaming but have edge cases:
- Browser EventSource auto-reconnects create duplicate connections
- Go's HTTP request context gets cancelled when the handler returns (but goroutines may still be running)
- Client ID management across reconnects needs pointer-based comparison, not just string matching
- Consider WebSockets if you need bidirectional communication or more control over connection lifecycle

### 4. NodePort Works But Isn't Production-Ready
Accessing EKS services via NodePort + internal IPs works for a demo but:
- Node IPs change when nodes are replaced (Karpenter spot interruptions)
- No load balancing across nodes
- Security group rules must be manually managed
- Use AWS Load Balancer Controller + Ingress/Service type LoadBalancer for production

### 5. Large Docker Images Kill Velocity
The rag-service image was 4.5GB and Airflow was 9.45GB. ECR pushes took 30+ minutes on residential upload speeds. Strategies:
- Build images on EC2 (fast network to ECR) instead of pushing from local
- Use multi-stage builds aggressively
- Pin slim base images
- Consider building on CI/CD (GitHub Actions with AWS runners)

---

## Files Modified From Original Plan

| File | Change | Why |
|------|--------|-----|
| `app/rag/main.py` | `BatchSpanExporter` → `BatchSpanProcessor` | Wrong OTel class name |
| `app/rag/rag/retriever.py` | Replaced LangChain retriever with direct Qdrant client | LangChain couldn't read flat payload metadata |
| `app/rag/rag/generator.py` | `page` → `filing_date` in source labels | Our data has dates, not page numbers |
| `app/chat/handlers/handlers.go` | `r.Context()` → `context.Background()` for goroutine | Request context cancelled goroutine prematurely |
| `app/chat/sse/hub.go` | Pointer comparison in Unregister | Race condition deleted new connections |
| `app/chat/templates/index.html` | Close old EventSource before reconnect | Duplicate SSE connections |

---

## Infrastructure State at Demo Time

- **EKS**: 4 nodes (2 CPU t3.medium + 2 GPU g5.xlarge spot)
- **EC2**: 1x t3.medium with EIP, running chat-app + rag-service via docker-compose
- **Qdrant**: 4741 vectors from 10 SEC filings (5 companies x 2 filings each)
- **vLLM**: 2 replicas, Qwen2.5-1.5B-Instruct, ~60-97 tok/s per replica
- **Networking**: EC2 → EKS via NodePort (vLLM:31906, Qdrant:31768, OTel:31285)
- **Observability**: OTel Collector + Jaeger deployed (traces flowing)
- **Cost**: ~$8-10 for the session (mostly GPU spot instances)
