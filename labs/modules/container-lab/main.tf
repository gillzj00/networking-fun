# ---------- container-lab ----------
#
# Per-PR Fargate lab on the shared platform infrastructure: one task
# definition + one service per PR, discovered against the static lab VPC and
# ECS cluster that platform/ owns. Each fault scenario is a single deliberate
# misconfiguration; everything else stays correct so the probe isolates one
# failure mode at a time.
#
# Scenario faults:
#   happy-path                    everything correct
#   sg-port-mismatch              SG admits port 80, app listens on 8080
#   broken-task-execution-role    execution role cannot pull from ECR
#   bad-image-tag                 task definition pins a tag that does not exist
#   failing-health-check          shell-based health check in a scratch image
#   misconfigured-task-definition PORT env moves the app off the SG'd port

data "aws_vpc" "lab" {
  tags = {
    Name = "lab-network"
  }
}

data "aws_subnets" "lab_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.lab.id]
  }

  tags = {
    Tier = "public"
  }
}

data "aws_ecs_cluster" "labs" {
  cluster_name = "networking-fun-labs"
}

data "aws_ecr_repository" "hello" {
  name = "networking-fun/hello"
}

# Labs track the newest image on main. The image-build workflow only pushes
# immutable SHA tags, so the most recent image always carries exactly one tag.
data "aws_ecr_image" "hello_latest" {
  repository_name = data.aws_ecr_repository.hello.name
  most_recent     = true
}

locals {
  name_prefix = "lab-pr-${var.pr_number}"
  app_port    = 8080

  image_tag = var.scenario == "bad-image-tag" ? "does-not-exist" : one(data.aws_ecr_image.hello_latest.image_tags)
  image     = "${data.aws_ecr_repository.hello.repository_url}:${local.image_tag}"

  ingress_port = var.scenario == "sg-port-mismatch" ? 80 : local.app_port

  container_environment = var.scenario == "misconfigured-task-definition" ? [
    { name = "PORT", value = "9090" }
  ] : []

  # The hello image is built FROM scratch: no shell, no wget. This health
  # check is the classic mistake of assuming a shell exists in the container.
  container_health_check = var.scenario == "failing-health-check" ? {
    command     = ["CMD-SHELL", "wget -q -O - http://localhost:${local.app_port}/healthz || exit 1"]
    interval    = 5
    timeout     = 2
    retries     = 2
    startPeriod = 5
  } : null
}

resource "aws_cloudwatch_log_group" "lab" {
  #checkov:skip=CKV_AWS_158:Portfolio lab; AWS-managed encryption is sufficient.
  #checkov:skip=CKV_AWS_338:1-day retention bounds cost for ephemeral lab logs.
  name              = "/networking-fun/labs/pr-${var.pr_number}"
  retention_in_days = var.log_retention_days
}

# Execution role: ECR pull + log delivery. The broken-task-execution-role
# scenario omits the ECR statements so the ECS agent cannot authenticate to
# the registry and the task dies with a ResourceInitializationError.

data "aws_iam_policy_document" "execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-execution"
  description        = "Execution role for the PR ${var.pr_number} lab task."
  assume_role_policy = data.aws_iam_policy_document.execution_assume.json
}

data "aws_iam_policy_document" "execution" {
  dynamic "statement" {
    for_each = var.scenario == "broken-task-execution-role" ? [] : [1]

    content {
      # GetAuthorizationToken does not support resource-level scoping.
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.scenario == "broken-task-execution-role" ? [] : [1]

    content {
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
      ]
      resources = [data.aws_ecr_repository.hello.arn]
    }
  }

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lab.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "${local.name_prefix}-execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

resource "aws_security_group" "lab" {
  #checkov:skip=CKV_AWS_260:The public HTTP endpoint is the point of the lab.
  name        = local.name_prefix
  description = "Public HTTP endpoint for the PR ${var.pr_number} lab task."
  vpc_id      = data.aws_vpc.lab.id

  ingress {
    description = "lab HTTP endpoint"
    from_port   = local.ingress_port
    to_port     = local.ingress_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS only: image pull from ECR and awslogs delivery.
  egress {
    description = "ECR pull and CloudWatch Logs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = local.name_prefix
  }
}

resource "aws_ecs_task_definition" "lab" {
  family                   = "${local.name_prefix}-hello"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  # The image-build workflow builds on amd64 GitHub runners.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "hello"
      image     = local.image
      essential = true

      portMappings = [
        {
          containerPort = local.app_port
          protocol      = "tcp"
        }
      ]

      environment            = local.container_environment
      healthCheck            = local.container_health_check
      readonlyRootFilesystem = true

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.lab.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "pr-${var.pr_number}"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "lab" {
  #checkov:skip=CKV_AWS_333:Tasks need public IPs to pull from ECR; the lab VPC has no NAT by design.
  name            = local.name_prefix
  cluster         = data.aws_ecs_cluster.labs.id
  task_definition = aws_ecs_task_definition.lab.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  propagate_tags  = "SERVICE"

  # Fault scenarios launch tasks that can never stabilise; the circuit
  # breaker marks the deployment FAILED after a few attempts instead of
  # relaunching doomed tasks for the whole TTL. No rollback: there is no
  # previous deployment to roll back to.
  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  network_configuration {
    subnets          = data.aws_subnets.lab_public.ids
    security_groups  = [aws_security_group.lab.id]
    assign_public_ip = true
  }
}
