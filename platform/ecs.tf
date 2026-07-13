# ---------- ECS cluster + hello Fargate service ----------
#
# The cluster and task definition are free; the service idles at
# hello_desired_count = 0 so steady-state cost is zero. Demos run either by
# bumping the count (via PR) or with a one-off `aws ecs run-task` against
# the same task definition. Per-PR lab services arrive in a later slice.

resource "aws_ecs_cluster" "labs" {
  #checkov:skip=CKV_AWS_65:Container Insights bills custom CloudWatch metrics; not warranted for a cluster that idles at zero tasks.
  name = "networking-fun-labs"
}

resource "aws_cloudwatch_log_group" "hello" {
  #checkov:skip=CKV_AWS_158:Portfolio lab; AWS-managed encryption is sufficient, customer KMS adds rotation burden disproportionate to value.
  #checkov:skip=CKV_AWS_338:1-day retention bounds cost for demo task logs.
  name              = "/networking-fun/platform/hello"
  retention_in_days = var.hello_log_retention_days
}

# Execution role: what the ECS agent uses to pull the image and ship logs.
# Scoped to the one repository and log group instead of the AWS managed
# policy. The task itself makes no AWS calls, so there is no task role.

data "aws_iam_policy_document" "hello_execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hello_execution" {
  name               = "hello-task-execution"
  description        = "Execution role for the hello Fargate task: ECR pull + CloudWatch logs."
  assume_role_policy = data.aws_iam_policy_document.hello_execution_assume.json
}

data "aws_iam_policy_document" "hello_execution" {
  statement {
    # GetAuthorizationToken does not support resource-level scoping.
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.hello.arn]
  }

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.hello.arn}:*"]
  }
}

resource "aws_iam_role_policy" "hello_execution" {
  name   = "hello-task-execution"
  role   = aws_iam_role.hello_execution.id
  policy = data.aws_iam_policy_document.hello_execution.json
}

resource "aws_ecs_task_definition" "hello" {
  family                   = "hello"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.hello_execution.arn

  # The image-build workflow builds on amd64 GitHub runners; keep the task on
  # X86_64 until the pipeline produces arm64 images.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "hello"
      image     = "${aws_ecr_repository.hello.repository_url}:${var.hello_image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 8080
          protocol      = "tcp"
        }
      ]

      readonlyRootFilesystem = true

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.hello.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "hello"
        }
      }
    }
  ])
}

resource "aws_security_group" "hello" {
  #checkov:skip=CKV_AWS_260:Port 8080 is the public demo endpoint; that exposure is the point of the lab.
  name        = "lab-hello-service"
  description = "Public HTTP demo endpoint for the hello Fargate service."
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "hello HTTP endpoint"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS only: image pull from ECR and awslogs delivery. DNS to the VPC
  # resolver bypasses security-group evaluation, so no extra rule is needed.
  egress {
    description = "ECR pull and CloudWatch Logs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lab-hello-service"
  }
}

resource "aws_ecs_service" "hello" {
  #checkov:skip=CKV_AWS_333:Tasks need public IPs to pull from ECR; the free lab VPC has no NAT gateway by design.
  name            = "hello"
  cluster         = aws_ecs_cluster.labs.id
  task_definition = aws_ecs_task_definition.hello.arn
  desired_count   = var.hello_desired_count
  launch_type     = "FARGATE"
  propagate_tags  = "SERVICE"

  network_configuration {
    subnets          = aws_subnet.lab_public[*].id
    security_groups  = [aws_security_group.hello.id]
    assign_public_ip = true
  }
}
