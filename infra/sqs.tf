# ── SQS Queues ───────────────────────────────────
# Decouples Go app from inference backend

resource "aws_sqs_queue" "inference_requests" {
  name                       = "${var.project_name}-inference-requests"
  visibility_timeout_seconds = 120 # LLM inference can take time
  message_retention_seconds  = 3600 # 1 hour — demo, no need for long retention
  receive_wait_time_seconds  = 10  # Long polling — reduces empty receives

  tags = var.tags
}

resource "aws_sqs_queue" "inference_requests_dlq" {
  name                      = "${var.project_name}-inference-requests-dlq"
  message_retention_seconds = 86400 # 1 day for dead letters

  tags = var.tags
}

resource "aws_sqs_queue_redrive_policy" "inference_requests" {
  queue_url = aws_sqs_queue.inference_requests.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.inference_requests_dlq.arn
    maxReceiveCount     = 3
  })
}

# ── SQS for Airflow job triggers ─────────────────
resource "aws_sqs_queue" "ingestion_triggers" {
  name                       = "${var.project_name}-ingestion-triggers"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 3600

  tags = var.tags
}
