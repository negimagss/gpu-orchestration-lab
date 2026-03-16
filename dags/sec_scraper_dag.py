"""
DAG 1: SEC EDGAR Scraper
Scrapes 10-K filings from SEC EDGAR and stores PDFs in S3.
"""
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

# SEC EDGAR API base URL (free, no API key needed)
EDGAR_BASE = "https://efts.sec.gov/LATEST"
EDGAR_SUBMISSIONS = "https://data.sec.gov/submissions"

# Companies to scrape — CIK numbers
COMPANIES = {
    "AAPL": {"cik": "0000320193", "name": "Apple Inc."},
    "TSLA": {"cik": "0001318605", "name": "Tesla Inc."},
    "MSFT": {"cik": "0000789019", "name": "Microsoft Corp."},
    "GOOGL": {"cik": "0001652044", "name": "Alphabet Inc."},
    "AMZN": {"cik": "0001018724", "name": "Amazon.com Inc."},
}

# SEC requires a User-Agent header with contact info
HEADERS = {
    "User-Agent": "InferOps Research Bot (inferops@demo.local)",
    "Accept-Encoding": "gzip, deflate",
}


def get_filing_urls(cik: str, filing_type: str = "10-K", count: int = 3) -> list:
    """Get recent filing URLs from SEC EDGAR for a company."""
    url = f"{EDGAR_SUBMISSIONS}/CIK{cik}.json"
    resp = requests.get(url, headers=HEADERS, timeout=30)
    resp.raise_for_status()
    data = resp.json()

    filings = data.get("filings", {}).get("recent", {})
    forms = filings.get("form", [])
    accession_numbers = filings.get("accessionNumber", [])
    primary_docs = filings.get("primaryDocument", [])
    filing_dates = filings.get("filingDate", [])

    results = []
    for i, form in enumerate(forms):
        if form == filing_type and len(results) < count:
            accession = accession_numbers[i].replace("-", "")
            doc = primary_docs[i]
            filing_url = (
                f"https://www.sec.gov/Archives/edgar/data/"
                f"{cik.lstrip('0')}/{accession}/{doc}"
            )
            results.append({
                "url": filing_url,
                "filing_date": filing_dates[i],
                "accession": accession_numbers[i],
                "form": form,
            })

    return results


def scrape_filings(**context):
    """Scrape SEC filings and upload to S3."""
    s3 = boto3.client("s3", region_name=AWS_REGION)
    total_downloaded = 0

    for ticker, company_info in COMPANIES.items():
        cik = company_info["cik"]
        name = company_info["name"]
        logger.info(f"Scraping filings for {name} ({ticker})...")

        try:
            filings = get_filing_urls(cik, filing_type="10-K", count=2)
            logger.info(f"Found {len(filings)} 10-K filings for {ticker}")

            for filing in filings:
                # Download the filing
                resp = requests.get(filing["url"], headers=HEADERS, timeout=60)
                if resp.status_code != 200:
                    logger.warning(f"Failed to download {filing['url']}: {resp.status_code}")
                    continue

                # Upload to S3
                s3_key = (
                    f"sec-filings/{ticker}/{filing['form']}/"
                    f"{filing['filing_date']}_{filing['accession']}.html"
                )

                s3.put_object(
                    Bucket=S3_BUCKET,
                    Key=s3_key,
                    Body=resp.content,
                    ContentType="text/html",
                    Metadata={
                        "ticker": ticker,
                        "company": name,
                        "filing_type": filing["form"],
                        "filing_date": filing["filing_date"],
                        "source_url": filing["url"],
                    },
                )

                total_downloaded += 1
                logger.info(f"Uploaded: s3://{S3_BUCKET}/{s3_key}")

        except Exception as e:
            logger.error(f"Error scraping {ticker}: {e}")
            continue

    logger.info(f"Scraping complete. Total filings downloaded: {total_downloaded}")

    # Push count to XCom for downstream tasks
    context["ti"].xcom_push(key="filings_downloaded", value=total_downloaded)


def verify_s3_files(**context):
    """Verify files were uploaded to S3."""
    s3 = boto3.client("s3", region_name=AWS_REGION)
    response = s3.list_objects_v2(
        Bucket=S3_BUCKET, Prefix="sec-filings/", MaxKeys=100
    )
    file_count = response.get("KeyCount", 0)
    logger.info(f"Total SEC filing files in S3: {file_count}")
    context["ti"].xcom_push(key="s3_file_count", value=file_count)


# ── DAG Definition ───────────────────────────────
default_args = {
    "owner": "inferops",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="sec_edgar_scraper",
    default_args=default_args,
    description="Scrape SEC EDGAR 10-K filings and store in S3",
    schedule_interval=None,  # Manual trigger for demo
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["sec", "scraper", "data-ingestion"],
) as dag:

    scrape_task = PythonOperator(
        task_id="scrape_sec_filings",
        python_callable=scrape_filings,
    )

    verify_task = PythonOperator(
        task_id="verify_s3_uploads",
        python_callable=verify_s3_files,
    )

    scrape_task >> verify_task
