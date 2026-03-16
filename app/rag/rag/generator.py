import json
import logging
from typing import AsyncGenerator, List

import httpx

from config.settings import settings

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are a financial analyst assistant. Your job is to answer questions
about company financials using ONLY the provided context from SEC filings.

Rules:
1. ONLY use information from the provided context to answer questions.
2. If the context doesn't contain enough information, say so clearly.
3. Always cite which document/filing the information comes from.
4. Be precise with numbers — do not round or estimate.
5. If asked about something not in the context, say "I don't have that information in the available filings."
"""


class ResponseGenerator:
    """Generates responses using vLLM with retrieved context."""

    def __init__(self):
        self.base_url = settings.vllm_base_url
        self.model = settings.model_name
        self.client = httpx.AsyncClient(timeout=120.0)
        logger.info(f"Generator initialized: model={self.model}, url={self.base_url}")

    async def generate_stream(
        self, query: str, context_docs: List[dict]
    ) -> AsyncGenerator[dict, None]:
        """Stream response tokens from vLLM.

        Yields dicts with type: 'token', 'source', 'done', or 'error'
        """
        # Build context string from retrieved docs
        context_parts = []
        sources = []
        for i, doc in enumerate(context_docs):
            meta = doc.get("metadata", {})
            source_label = (
                f"{meta.get('company', 'Unknown')} - "
                f"{meta.get('filing_type', 'Filing')} - "
                f"{meta.get('filing_date', 'N/A')}"
            )
            context_parts.append(
                f"[Document {i+1} | {source_label}]\n{doc['content']}"
            )
            sources.append(source_label)

        context_str = "\n\n---\n\n".join(context_parts)

        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": (
                    f"Context from SEC filings:\n\n{context_str}\n\n"
                    f"Question: {query}"
                ),
            },
        ]

        payload = {
            "model": self.model,
            "messages": messages,
            "stream": True,
            "max_tokens": 1024,
            "temperature": 0.1,  # Low temp for factual accuracy
        }

        try:
            async with self.client.stream(
                "POST",
                f"{self.base_url}/chat/completions",
                json=payload,
            ) as response:
                if response.status_code != 200:
                    error_body = await response.aread()
                    yield {
                        "type": "error",
                        "content": f"vLLM error ({response.status_code}): {error_body.decode()}",
                    }
                    return

                async for line in response.aiter_lines():
                    if not line.startswith("data: "):
                        continue

                    data = line[6:]
                    if data == "[DONE]":
                        break

                    try:
                        chunk = json.loads(data)
                        delta = chunk["choices"][0].get("delta", {})
                        content = delta.get("content", "")
                        if content:
                            yield {"type": "token", "content": content}
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue

            # Send sources after generation completes
            for source in sources:
                yield {"type": "source", "content": source}

            yield {"type": "done", "content": ""}

        except httpx.ConnectError as e:
            logger.error(f"Failed to connect to vLLM: {e}")
            yield {
                "type": "error",
                "content": "Model service unavailable. Please try again.",
            }
        except Exception as e:
            logger.error(f"Generation error: {e}")
            yield {"type": "error", "content": str(e)}

    async def close(self):
        """Close the HTTP client."""
        await self.client.aclose()
