from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # vLLM endpoint (running on EKS)
    vllm_base_url: str = "http://vllm.inference.svc.cluster.local:8000/v1"
    model_name: str = "Qwen/Qwen2.5-1.5B-Instruct"

    # Qdrant (running on EKS)
    qdrant_url: str = "http://qdrant.data.svc.cluster.local:6333"
    qdrant_collection: str = "sec_filings"

    # Embedding model (runs locally in the RAG service)
    embedding_model: str = "all-MiniLM-L6-v2"
    embedding_dimension: int = 384

    # RAG settings
    chunk_size: int = 1000
    chunk_overlap: int = 200
    top_k: int = 5

    # OpenTelemetry
    otel_exporter_otlp_endpoint: str = "http://otel-collector.observability.svc.cluster.local:4317"
    otel_service_name: str = "inferops-rag-service"

    # Server
    host: str = "0.0.0.0"
    port: int = 8000

    class Config:
        env_prefix = ""
        case_sensitive = False


settings = Settings()
