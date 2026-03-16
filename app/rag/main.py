import json
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sse_starlette.sse import EventSourceResponse
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from config.settings import settings
from rag.retriever import DocumentRetriever
from rag.generator import ResponseGenerator

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Globals
retriever = None
generator = None


def init_tracing():
    """Initialize OpenTelemetry tracing."""
    resource = Resource.create({"service.name": settings.otel_service_name})
    provider = TracerProvider(resource=resource)

    try:
        exporter = OTLPSpanExporter(
            endpoint=settings.otel_exporter_otlp_endpoint,
            insecure=True,
        )
        provider.add_span_processor(BatchSpanProcessor(exporter))
        logger.info(f"OTel tracing enabled: {settings.otel_exporter_otlp_endpoint}")
    except Exception as e:
        logger.warning(f"Failed to init OTel exporter: {e}")

    trace.set_tracer_provider(provider)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application startup and shutdown."""
    global retriever, generator

    # Init tracing
    init_tracing()

    # Init RAG components
    logger.info("Initializing RAG components...")
    retriever = DocumentRetriever()
    generator = ResponseGenerator()
    logger.info("RAG service ready")

    yield

    # Cleanup
    await generator.close()
    logger.info("RAG service shutdown")


app = FastAPI(
    title="InferOps RAG Service",
    description="Financial document RAG with LangChain + vLLM",
    version="0.1.0",
    lifespan=lifespan,
)

# Instrument FastAPI with OTel
FastAPIInstrumentor.instrument_app(app)
tracer = trace.get_tracer("inferops-rag")


@app.get("/health")
async def health():
    """Health check endpoint."""
    qdrant_ok = retriever.health_check() if retriever else False
    return {
        "status": "healthy" if qdrant_ok else "degraded",
        "service": "inferops-rag",
        "qdrant": "connected" if qdrant_ok else "disconnected",
    }


@app.post("/api/query")
async def query(request: Request):
    """Handle a RAG query — retrieve context and stream LLM response."""
    body = await request.json()
    user_query = body.get("query", "")
    client_id = body.get("client_id", "unknown")

    if not user_query:
        return JSONResponse(
            status_code=400,
            content={"error": "query is required"},
        )

    with tracer.start_as_current_span("rag.query") as span:
        span.set_attribute("rag.query", user_query)
        span.set_attribute("rag.client_id", client_id)

        # Step 1: Retrieve relevant documents
        retrieval_start = time.time()
        with tracer.start_as_current_span("rag.retrieve"):
            context_docs = retriever.retrieve(user_query)
        retrieval_time = time.time() - retrieval_start

        span.set_attribute("rag.retrieval_time_ms", int(retrieval_time * 1000))
        span.set_attribute("rag.num_docs_retrieved", len(context_docs))

        logger.info(
            f"Query from {client_id}: '{user_query[:80]}...' "
            f"| Retrieved {len(context_docs)} docs in {retrieval_time:.3f}s"
        )

        # Step 2: Stream response from LLM
        async def event_generator():
            token_count = 0
            gen_start = time.time()

            with tracer.start_as_current_span("rag.generate"):
                async for chunk in generator.generate_stream(user_query, context_docs):
                    if chunk["type"] == "token":
                        token_count += 1
                    yield {
                        "event": "message",
                        "data": json.dumps(chunk),
                    }

            gen_time = time.time() - gen_start
            span.set_attribute("rag.generation_time_ms", int(gen_time * 1000))
            span.set_attribute("rag.token_count", token_count)
            if gen_time > 0:
                span.set_attribute("rag.tokens_per_second", round(token_count / gen_time, 2))

            logger.info(
                f"Generated {token_count} tokens in {gen_time:.3f}s "
                f"({token_count/gen_time:.1f} tok/s)" if gen_time > 0 else ""
            )

        return EventSourceResponse(event_generator())


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=settings.host, port=settings.port)
