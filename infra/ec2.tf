# ── EC2 App Server (Product Team) ────────────────
# Runs Go chat app + Python RAG service

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.ec2_instance_type
  key_name               = var.ec2_key_name != "" ? var.ec2_key_name : null
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.app_server.id]
  iam_instance_profile   = aws_iam_instance_profile.app_server.name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/templates/ec2_userdata.sh", {
    aws_region     = var.aws_region
    ecr_registry   = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    project_name   = var.project_name
    eks_endpoint   = module.eks.cluster_endpoint
    sqs_queue_url  = aws_sqs_queue.inference_requests.url
  }))

  tags = merge(var.tags, {
    Name = "${var.project_name}-app-server"
    Role = "product-team"
  })
}

data "aws_caller_identity" "current" {}

# ── Security Group for App Server ────────────────
resource "aws_security_group" "app_server" {
  name        = "${var.project_name}-app-server-sg"
  description = "Security group for InferOps app server"
  vpc_id      = module.vpc.vpc_id

  # HTTP from ALB
  ingress {
    description     = "HTTP from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_public.id]
  }

  # SSH (optional — only if key pair provided)
  dynamic "ingress" {
    for_each = var.ec2_key_name != "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"] # Demo only — lock down in prod
    }
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# ── IAM Role for App Server ─────────────────────
resource "aws_iam_role" "app_server" {
  name = "${var.project_name}-app-server-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "app_server_ecr" {
  role       = aws_iam_role.app_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "app_server_ssm" {
  role       = aws_iam_role.app_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app_server_sqs" {
  name = "${var.project_name}-app-server-sqs"
  role = aws_iam_role.app_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = [
        aws_sqs_queue.inference_requests.arn,
        aws_sqs_queue.ingestion_triggers.arn
      ]
    }]
  })
}

resource "aws_iam_role_policy" "app_server_s3" {
  name = "${var.project_name}-app-server-s3"
  role = aws_iam_role.app_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.data.arn,
        "${aws_s3_bucket.data.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "app_server" {
  name = "${var.project_name}-app-server-profile"
  role = aws_iam_role.app_server.name
}
