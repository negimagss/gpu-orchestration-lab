# ── vLLM with Qwen 2.5 1.5B ─────────────────────
# Based on official vLLM image with CUDA support
FROM vllm/vllm-openai:v0.4.1

# Model will be downloaded at startup via HuggingFace
# No model baked into image — keeps image small
ENV MODEL_NAME="Qwen/Qwen2.5-1.5B-Instruct"
ENV MAX_MODEL_LEN="4096"
ENV GPU_MEMORY_UTILIZATION="0.90"
ENV DTYPE="half"

EXPOSE 8000

CMD ["python3", "-m", "vllm.entrypoints.openai.api_server", \
     "--model", "${MODEL_NAME}", \
     "--max-model-len", "${MAX_MODEL_LEN}", \
     "--gpu-memory-utilization", "${GPU_MEMORY_UTILIZATION}", \
     "--dtype", "${DTYPE}", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--trust-remote-code"]
