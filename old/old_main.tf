# AWS Provider Configuration
provider "aws" {
  region = "us-east-1" # Choose your desired AWS region
}

# EFS for shared SQLite Database
resource "aws_efs_file_system" "rss_db" {
  count = var.create_efs ? 1 : 0
  
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "rss_db"
  }
}

resource "aws_efs_mount_target" "rss_db_mount" {
  count = var.create_efs ? length(data.aws_availability_zones.available.names) : 0

  file_system_id  = aws_efs_file_system.rss_db[0].id
  subnet_id       = tolist(data.aws_subnets.available.ids)[count.index]
  security_groups = [aws_security_group.efs_sg.id]
}

data "aws_availability_zones" "available" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "available" {

}

resource "aws_security_group" "efs_sg" {
  name = "allow_efs"

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECS Configuration
resource "aws_ecs_cluster" "rss_analyzer" {
  name = "rss_analyzer"
}

resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Effect = "Allow"
    }]
  })
}

resource "aws_iam_role" "ecs_task_role" {
  name = "ecs_task_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Effect = "Allow"
    }]
  })
}

# Generic ECS Task Definition for Microservices
resource "aws_ecs_task_definition" "microservice" {
  for_each = {
    rss_feed_crawler = { image = "roboworksolutions/rss-feed-crawler-microservice:latest", container_port = 5001, host_port = 5001 },
    rss_sentiment_classifier = { image = "roboworksolutions/rss-sentiment-classifier-microservice:latest", container_port = 5003, host_port = 5003 },
    rss_classifier = { image = "roboworksolutions/rss-classifier-microservice:latest", container_port = 5000, host_port = 5000 },
    rss_reader = { image = "roboworksolutions/rss-reader-microservice:latest", container_port = 5002, host_port = 5002 }
  }

  family                   = each.key
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name  = each.key
    image = each.value.image
    portMappings = [{
      containerPort = each.value.container_port
      hostPort      = each.value.host_port
    }]
    mountPoints = [{
      sourceVolume  = "rss_db_volume"
      containerPath = "/usr/src/app/rss_links.db"
    }]
  }])

  volume {
    name = "rss_db_volume"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.rss_db[0].id
    }
  }
}

# Generic ECS Service for Microservices
resource "aws_ecs_service" "microservice" {
  for_each = aws_ecs_task_definition.microservice

  name            = each.key
  cluster         = aws_ecs_cluster.rss_analyzer.id
  task_definition = each.value.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets = data.aws_subnets.available.ids
    security_groups = [aws_security_group.efs_sg.id]
  }
}

# Variables
variable "create_efs" {
  description = "Whether to create EFS storage or not. Set to false if EFS already exists."
  default     = true
}