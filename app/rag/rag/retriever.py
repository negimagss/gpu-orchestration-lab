import logging
from typing import List

from langchain_community.embeddings import HuggingFaceEmbeddings
from qdrant_client import QdrantClient, models

from config.settings import settings

logger = logging.getLogger(__name__)


class DocumentRetriever:
    """Retrieves relevant document chunks from Qdrant for RAG."""

    def __init__(self):
        self.embeddings = HuggingFaceEmbeddings(
            model_name=settings.embedding_model,
            model_kwargs={"device": "cpu"},
        )

        self.qdrant_client = QdrantClient(url=settings.qdrant_url)

        logger.info(
            f"Retriever initialized: collection={settings.qdrant_collection}, "
            f"top_k={settings.top_k}, embedding_model={settings.embedding_model}"
        )

    def retrieve(self, query: str) -> List[dict]:
        """Retrieve relevant documents for a query.

        Returns list of dicts with 'content' and 'metadata' keys.
        """
        query_vector = self.embeddings.embed_query(query)

        hits = self.qdrant_client.search(
            collection_name=settings.qdrant_collection,
            query_vector=query_vector,
            limit=settings.top_k,
        )

        results = []
        for hit in hits:
            payload = hit.payload or {}
            results.append({
                "content": payload.get("text", ""),
                "metadata": {
                    "company": payload.get("company", "Unknown"),
                    "filing_type": payload.get("filing_type", "Filing"),
                    "filing_date": payload.get("filing_date", "N/A"),
                    "ticker": payload.get("ticker", ""),
                    "chunk_index": payload.get("chunk_index", 0),
                },
            })

        logger.info(f"Retrieved {len(results)} chunks for query: {query[:80]}...")
        return results

    def health_check(self) -> bool:
        """Check if Qdrant is reachable and collection exists."""
        try:
            collections = self.qdrant_client.get_collections()
            names = [c.name for c in collections.collections]
            return settings.qdrant_collection in names
        except Exception as e:
            logger.error(f"Qdrant health check failed: {e}")
            return False
