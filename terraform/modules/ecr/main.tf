variable "name" {
  type = string
}

resource "aws_ecr_repository" "app" {
  name                 = "${var.name}-app"
  image_tag_mutability = "IMMUTABLE" # deploy by digest/sha, never overwrite :latest

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.name}-app" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy     = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_url" {
  value = aws_ecr_repository.app.repository_url
}
