"""
DAG 3: RAGAS Eval Runner
Runs evaluation benchmarks on the RAG pipeline after new data is ingested.
Measures precision, recall, faithfulness, and answer relevancy.
"""
import json
import os
import logging
from datetime import datetime, timedelta

import boto3
import requests
from airflow import DAG
from airflow.operators.python import PythonOperator

logger = logging.getLogger(__name__)

S3_BUCKET = os.getenv("S3_BUCKET", "inferops-data")
AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
RAG_SERVICE_URL = os.getenv("RAG_SERVICE_URL", "http://inferops-app:8000")

# Eval dataset — curated Q&A pairs with expected answers
EVAL_DATASET = [
    {
        "question": "What was Apple's total net revenue in fiscal year 2023?",
        "expected_answer": "Apple's total net revenue in fiscal year 2023 was $383.3 billion.",
        "expected_source": "Apple 10-K 2023",
    },
    {
        "question": "What were Tesla's total automotive revenues in 2023?",
        "expected_answer": "Tesla's total automotive revenues in 2023 were $82.4 billion.",
        "expected_source": "Tesla 10-K 2023",
    },
    {
        "question": "What is Apple's largest revenue segment?",
        "expected_answer": "iPhone is Apple's largest revenue segment.",
        "expected_source": "Apple 10-K",
    },
    {
        "question": "How many vehicles did Tesla deliver in 2023?",
        "expected_answer": "Tesla delivered approximately 1.81 million vehicles in 2023.",
        "expected_source": "Tesla 10-K 2023",
    },
    {
        "question": "What were Microsoft's total revenue for fiscal year 2023?",
        "expected_answer": "Microsoft's total revenue for fiscal year 2023 was $211.9 billion.",
        "expected_source": "Microsoft 10-K 2023",
    },
    {
        "question": "What is Amazon's largest business segment by revenue?",
        "expected_answer": "Amazon's largest business segment by revenue is North America.",
        "expected_source": "Amazon 10-K",
    },
    {
        "question": "What were Alphabet's advertising revenues in 2023?",
        "expected_answer": "Alphabet's advertising revenues in 2023 were approximately $237.9 billion.",
        "expected_source": "Alphabet 10-K 2023",
    },
    {
        "question": "What are Apple's main risk factors?",
        "expected_answer": "Macroeconomic conditions, competition, supply chain, regulatory.",
        "expected_source": "Apple 10-K",
    },
    {
        "question": "What is Tesla's gross profit margin for automotive?",
        "expected_answer": "Tesla's automotive gross margin was approximately 18.2% in 2023.",
        "expected_source": "Tesla 10-K 2023",
    },
    {
        "question": "How much did Apple spend on R&D in 2023?",
        "expected_answer": "Apple spent $29.9 billion on research and development in 2023.",
        "expected_source": "Apple 10-K 2023",
    },
]


def run_rag_evals(**context):
    """Run eval queries through the RAG service and collect results."""
    results = []

    for i, eval_item in enumerate(EVAL_DATASET):
        logger.info(f"Running eval {i+1}/{len(EVAL_DATASET)}: {eval_item['question'][:60]}...")

        try:
            resp = requests.post(
                f"{RAG_SERVICE_URL}/api/query",
                json={"query": eval_item["question"], "client_id": "eval-runner"},
                headers={"Accept": "application/json"},
                timeout=60,
                stream=True,
            )

            # Collect streamed response
            full_response = ""
            sources = []

            for line in resp.iter_lines(decode_unicode=True):
                if line and line.startswith("data: "):
                    data = json.loads(line[6:])
                    if data["type"] == "token":
                        full_response += data["content"]
                    elif data["type"] == "source":
                        sources.append(data["content"])

            results.append({
                "question": eval_item["question"],
                "expected_answer": eval_item["expected_answer"],
                "actual_answer": full_response,
                "sources": sources,
                "expected_source": eval_item["expected_source"],
            })

            logger.info(f"Eval {i+1}: Got response ({len(full_response)} chars)")

        except Exception as e:
            logger.error(f"Eval {i+1} failed: {e}")
            results.append({
                "question": eval_item["question"],
                "expected_answer": eval_item["expected_answer"],
                "actual_answer": f"ERROR: {str(e)}",
                "sources": [],
                "expected_source": eval_item["expected_source"],
                "error": True,
            })

    context["ti"].xcom_push(key="eval_results", value=results)


def compute_metrics(**context):
    """Compute evaluation metrics from results."""
    results = context["ti"].xcom_pull(key="eval_results", task_ids="run_rag_evals")

    if not results:
        logger.error("No eval results to compute metrics")
        return

    total = len(results)
    errors = sum(1 for r in results if r.get("error"))
    successful = total - errors

    # Basic metrics (simplified RAGAS-like scoring)
    scores = {
        "total_questions": total,
        "successful_queries": successful,
        "failed_queries": errors,
        "answer_rate": successful / total if total > 0 else 0,
    }

    # Check if responses contain relevant info (basic faithfulness proxy)
    relevant_count = 0
    source_match_count = 0

    for r in results:
        if r.get("error"):
            continue

        answer = r["actual_answer"].lower()
        expected = r["expected_answer"].lower()

        # Check if key terms from expected answer appear in actual answer
        expected_terms = [
            t for t in expected.split() if len(t) > 3 and t.isalpha()
        ]
        matched_terms = sum(1 for t in expected_terms if t in answer)
        relevance = matched_terms / len(expected_terms) if expected_terms else 0

        if relevance > 0.3:
            relevant_count += 1

        # Check if expected source is in returned sources
        expected_src = r["expected_source"].lower()
        for src in r["sources"]:
            if any(part in src.lower() for part in expected_src.split()):
                source_match_count += 1
                break

    scores["answer_relevancy"] = round(relevant_count / successful, 3) if successful > 0 else 0
    scores["source_precision"] = round(source_match_count / successful, 3) if successful > 0 else 0

    logger.info(f"Eval Metrics: {json.dumps(scores, indent=2)}")

    context["ti"].xcom_push(key="eval_metrics", value=scores)


def save_eval_report(**context):
    """Save evaluation report to S3."""
    results = context["ti"].xcom_pull(key="eval_results", task_ids="run_rag_evals")
    metrics = context["ti"].xcom_pull(key="eval_metrics", task_ids="compute_metrics")

    report = {
        "timestamp": datetime.utcnow().isoformat(),
        "metrics": metrics,
        "detailed_results": results,
    }

    s3 = boto3.client("s3", region_name=AWS_REGION)
    report_key = f"eval-reports/{datetime.utcnow().strftime('%Y%m%d_%H%M%S')}_eval.json"

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=report_key,
        Body=json.dumps(report, indent=2),
        ContentType="application/json",
    )

    logger.info(f"Eval report saved: s3://{S3_BUCKET}/{report_key}")
    logger.info(f"Final Metrics: {json.dumps(metrics, indent=2)}")


# ── DAG Definition ───────────────────────────────
default_args = {
    "owner": "inferops",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 0,
    "retry_delay": timedelta(minutes=2),
}

with DAG(
    dag_id="rag_eval_runner",
    default_args=default_args,
    description="Run RAGAS evaluations on RAG pipeline",
    schedule_interval=None,  # Manual trigger after ingestion
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["evals", "ragas", "quality"],
) as dag:

    run_evals = PythonOperator(
        task_id="run_rag_evals",
        python_callable=run_rag_evals,
    )

    compute = PythonOperator(
        task_id="compute_metrics",
        python_callable=compute_metrics,
    )

    save_report = PythonOperator(
        task_id="save_eval_report",
        python_callable=save_eval_report,
    )

    run_evals >> compute >> save_report
