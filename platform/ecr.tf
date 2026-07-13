# ---------- ECR repository for lab container images ----------
#
# First slice of the container-lab pivot: the image-build workflow builds
# apps/hello and pushes git-SHA-tagged images here on merge to main. The ECS
# Fargate lab service (a later slice) pulls from this repository.

resource "aws_ecr_repository" "hello" {
  #checkov:skip=CKV_AWS_136:Default AES256 is sufficient for public demo images; a KMS CMK adds $1/mo for no benefit.
  name                 = "networking-fun/hello"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # Lab images are disposable; let terraform destroy succeed even when the
  # repository still holds images.
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "hello" {
  repository = aws_ecr_repository.hello.name

  # Tags are immutable git SHAs and the hello task definition pins one, so
  # tagged images must never be expired by count -- a pinned tag disappearing
  # breaks run-task and the service. Tagged images are ~10 MB each, so keeping
  # them all costs pennies; only clean up untagged layers from failed pushes.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
