# ── Airflow with DAGs baked in ────────────────────
FROM apache/airflow:2.8.1-python3.11

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

USER airflow

# Install extra Python packages for DAGs
COPY docker/airflow/requirements-airflow.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Bake DAGs into the image
COPY dags/ /opt/airflow/dags/
