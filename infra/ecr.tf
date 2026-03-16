# ── ECR Repositories ─────────────────────────────
# All application images go through ECR — no direct injection

resource "aws_ecr_repository" "chat_app" {
  name                 = "${var.project_name}/chat-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # Demo — clean teardown

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_repository" "rag_service" {
  name                 = "${var.project_name}/rag-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_repository" "vllm" {
  name                 = "${var.project_name}/vllm"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_repository" "airflow" {
  name                 = "${var.project_name}/airflow"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

# ── ECR Lifecycle Policy (keep last 5 images) ───
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each   = toset(["chat-app", "rag-service", "vllm", "airflow"])
  repository = "${var.project_name}/${each.key}"

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })

  depends_on = [
    aws_ecr_repository.chat_app,
    aws_ecr_repository.rag_service,
    aws_ecr_repository.vllm,
    aws_ecr_repository.airflow,
  ]
}
