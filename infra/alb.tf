# ── Public ALB (Browser → Go App) ────────────────
resource "aws_lb" "public" {
  name               = "${var.project_name}-public-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_public.id]
  subnets            = module.vpc.public_subnets

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-alb"
  })
}

resource "aws_lb_target_group" "chat_app" {
  name     = "${var.project_name}-chat-app-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    path                = "/health"
    port                = "8080"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
  }

  tags = var.tags
}

resource "aws_lb_listener" "public_http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.chat_app.arn
  }
}

resource "aws_lb_target_group_attachment" "chat_app" {
  target_group_arn = aws_lb_target_group.chat_app.arn
  target_id        = aws_instance.app_server.id
  port             = 8080
}

# ── Security Group for Public ALB ────────────────
resource "aws_security_group" "alb_public" {
  name        = "${var.project_name}-alb-public-sg"
  description = "Security group for public ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}
