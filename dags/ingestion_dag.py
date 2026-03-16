"""
DAG 2: Document Ingestion Pipeline
Reads SEC filings from S3, chunks them, generates embeddings,
and loads into Qdrant vector database.
"""
import os
import logging
from datetime import datetime, timedelta

import boto3
from airflow import DAG
from airflow.operators.python import PythonOperator

from bs4 import BeautifulSoup
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain_community.embeddings import HuggingFaceEmbeddings
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct
import uuid

logger = logging.getLogger(__name__)

S3_BUCKET = os.getenv("S3_BUCKET", "inferops-data")
AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
QDRANT_URL = os.getenv("QDRANT_URL", "http://qdrant.data.svc.cluster.local:6333")
COLLECTION_NAME = "sec_filings"
EMBEDDING_MODEL = "all-MiniLM-L6-v2"
EMBEDDING_DIM = 384
CHUNK_SIZE = 1000
CHUNK_OVERLAP = 200


def ensure_collection():
    """Create Qdrant collection if it doesn't exist."""
    client = QdrantClient(url=QDRANT_URL)

    collections = [c.name for c in client.get_collections().collections]
    if COLLECTION_NAME not in collections:
        client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(
                size=EMBEDDING_DIM,
                distance=Distance.COSINE,
            ),
        )
        logger.info(f"Created Qdrant collection: {COLLECTION_NAME}")
    else:
        logger.info(f"Collection {COLLECTION_NAME} already exists")


def download_and_parse(**context):
    """Download SEC filings from S3 and parse HTML to text."""
    s3 = boto3.client("s3", region_name=AWS_REGION)

    response = s3.list_objects_v2(
        Bucket=S3_BUCKET, Prefix="sec-filings/"
    )

    documents = []
    for obj in response.get("Contents", []):
        key = obj["Key"]
        if not key.endswith(".html"):
            continue

        # Download file
        file_obj = s3.get_object(Bucket=S3_BUCKET, Key=key)
        html_content = file_obj["Body"].read().decode("utf-8", errors="ignore")
        metadata = file_obj.get("Metadata", {})

        # Parse HTML to text
        soup = BeautifulSoup(html_content, "html.parser")

        # Remove script and style elements
        for tag in soup(["script", "style"]):
            tag.decompose()

        text = soup.get_text(separator="\n", strip=True)

        # Clean up text
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        clean_text = "\n".join(lines)

        if len(clean_text) < 100:
            logger.warning(f"Skipping {key}: too short ({len(clean_text)} chars)")
            continue

        documents.append({
            "text": clean_text,
            "metadata": {
                "s3_key": key,
                "ticker": metadata.get("ticker", "UNKNOWN"),
                "company": metadata.get("company", "Unknown"),
                "filing_type": metadata.get("filing_type", "10-K"),
                "filing_date": metadata.get("filing_date", ""),
                "source_url": metadata.get("source_url", ""),
            },
        })
        logger.info(f"Parsed {key}: {len(clean_text)} chars")

    logger.info(f"Total documents parsed: {len(documents)}")
    context["ti"].xcom_push(key="parsed_doc_count", value=len(documents))

    # Store parsed docs temporarily (via XCom for small data, S3 for large)
    # For demo, we'll pass via XCom
    context["ti"].xcom_push(key="documents", value=documents)


def chunk_and_embed(**context):
    """Chunk documents and generate embeddings."""
    documents = context["ti"].xcom_pull(key="documents", task_ids="download_and_parse")

    if not documents:
        logger.warning("No documents to process")
        return

    # Initialize text splitter
    splitter = RecursiveCharacterTextSplitter(
        chunk_size=CHUNK_SIZE,
        chunk_overlap=CHUNK_OVERLAP,
        separators=["\n\n", "\n", ". ", " ", ""],
    )

    # Initialize embedding model
    embeddings = HuggingFaceEmbeddings(
        model_name=EMBEDDING_MODEL,
        model_kwargs={"device": "cpu"},
    )

    all_chunks = []

    for doc in documents:
        # Split into chunks
        chunks = splitter.split_text(doc["text"])
        logger.info(
            f"Document {doc['metadata']['ticker']}: "
            f"{len(doc['text'])} chars → {len(chunks)} chunks"
        )

        for i, chunk_text in enumerate(chunks):
            all_chunks.append({
                "text": chunk_text,
                "metadata": {
                    **doc["metadata"],
                    "chunk_index": i,
                    "chunk_total": len(chunks),
                },
            })

    logger.info(f"Total chunks: {len(all_chunks)}")

    # Generate embeddings in batches
    batch_size = 64
    all_points = []

    for i in range(0, len(all_chunks), batch_size):
        batch = all_chunks[i : i + batch_size]
        texts = [c["text"] for c in batch]
        vectors = embeddings.embed_documents(texts)

        for j, (chunk, vector) in enumerate(zip(batch, vectors)):
            point = PointStruct(
                id=str(uuid.uuid4()),
                vector=vector,
                payload={
                    "text": chunk["text"],
                    **chunk["metadata"],
                },
            )
            all_points.append(point)

        logger.info(f"Embedded batch {i//batch_size + 1}: {len(batch)} chunks")

    context["ti"].xcom_push(key="total_chunks", value=len(all_points))
    context["ti"].xcom_push(key="points", value=all_points)


def load_to_qdrant(**context):
    """Load embedded chunks into Qdrant."""
    points = context["ti"].xcom_pull(key="points", task_ids="chunk_and_embed")

    if not points:
        logger.warning("No points to load")
        return

    client = QdrantClient(url=QDRANT_URL)

    # Upsert in batches
    batch_size = 100
    for i in range(0, len(points), batch_size):
        batch = points[i : i + batch_size]
        client.upsert(
            collection_name=COLLECTION_NAME,
            points=batch,
        )
        logger.info(f"Loaded batch {i//batch_size + 1}: {len(batch)} points")

    # Verify
    collection_info = client.get_collection(COLLECTION_NAME)
    logger.info(
        f"Qdrant collection '{COLLECTION_NAME}' now has "
        f"{collection_info.points_count} points"
    )


# ── DAG Definition ───────────────────────────────
default_args = {
    "owner": "inferops",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
}

with DAG(
    dag_id="sec_document_ingestion",
    default_args=default_args,
    description="Parse, chunk, embed, and load SEC filings into Qdrant",
    schedule_interval=None,  # Triggered after scraper DAG
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["rag", "ingestion", "qdrant", "embeddings"],
) as dag:

    init_collection = PythonOperator(
        task_id="ensure_qdrant_collection",
        python_callable=ensure_collection,
    )

    parse = PythonOperator(
        task_id="download_and_parse",
        python_callable=download_and_parse,
    )

    embed = PythonOperator(
        task_id="chunk_and_embed",
        python_callable=chunk_and_embed,
    )

    load = PythonOperator(
        task_id="load_to_qdrant",
        python_callable=load_to_qdrant,
    )

    init_collection >> parse >> embed >> load
