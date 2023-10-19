# AWS Provider Configuration
provider "aws" {
  region = "us-west-2" # Choose your desired AWS region
}

# data "aws_iam_role" "ecs_task_role" {
#   name = "ecs_task_role"
# }

# data "aws_iam_role" "ecs_execution_role" {
#   name = "ecs_execution_role"
# }

# data "aws_security_group" "efs_sg" {
#   name = "allow_efs"
# }

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



#   tags = {
#     Name = "rss_db"
#   }
# }

# resource "aws_efs_mount_target" "rss_db_mount" {
#   count = var.create_efs ? length(data.aws_availability_zones.available.names) : 0

#   file_system_id  = aws_efs_file_system.rss_db[0].id
#   subnet_id       = tolist(data.aws_subnets.available.ids)[count.index]
#   security_groups = [aws_security_group.efs_sg.id]

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
# }

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

resource "aws_security_group" "ec2_ssh_sg" {
  name        = "ec2_ssh_sg"
  description = "Allow inbound SSH traffic"

  # Inbound rule to allow SSH (port 22) from a specific IP or CIDR range
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    # cidr_blocks = ["YOUR_IP_ADDRESS/32"]  # Replace with your IP or a CIDR range
  }

  # Usually, it's also a good idea to allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ec2_ssh_sg"
  }
}



resource "aws_ecs_task_definition" "microservice" {
  for_each = {
    rss_feed_crawler = { image = "roboworksolutions/rss-feed-crawler-microservice:latest", container_port = 5001, host_port = 5001 },
    rss_sentiment_classifier = { image = "roboworksolutions/rss-sentiment-classifier-microservice:latest", container_port = 5014, host_port = 5014 },
    rss_classifier = { image = "roboworksolutions/rss-classifier-microservice:latest", container_port = 5003, host_port = 5003 },
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
  }])

  # volume {
  #   name = "rss_db_volume"
  #   efs_volume_configuration {
  #     file_system_id = aws_efs_file_system.rss_db[0].id
  #   }
  # }
}

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
# CockroachDB Configuration

# Security Group for CockroachDB
resource "aws_security_group" "cockroachdb_sg" {
  name        = "cockroachdb_sg"
  description = "Allow CockroachDB-specific traffic"

  # Allow CockroachDB inter-node and client traffic
  ingress {
    from_port   = 26257
    to_port     = 26257
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow CockroachDB HTTP Admin UI traffic
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# CockroachDB Configuration for ECS Fargate

# ECS Task Definition for CockroachDB
resource "aws_ecs_task_definition" "cockroachdb" {
  family                   = "cockroachdb"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024" # 1 vCPU
  memory                   = "2048" # 2GB RAM
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  
  container_definitions = jsonencode([{
    name  = "cockroachdb"
    image = "cockroachdb/cockroach:latest"
    portMappings = [{
      containerPort = 26257
    }, {
      containerPort = 8080
    }],
    # Mount EFS for persistent storage
    mountPoints = [{
      sourceVolume  = "cockroachdb_data"
      containerPath = "/cockroach/cockroach-data"
    }],
    # Command to start CockroachDB (This needs to be adjusted for cluster join and initialization)
    command = ["start", "--insecure"]
  }])

  volume {
    name = "cockroachdb_data"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.cockroachdb_data.id
    }
  }
}

# ECS Service for CockroachDB
resource "aws_ecs_service" "cockroachdb" {
  name            = "cockroachdb"
  cluster         = aws_ecs_cluster.rss_analyzer.id
  task_definition = aws_ecs_task_definition.cockroachdb.arn
  launch_type     = "FARGATE"
  desired_count   = 5

  network_configuration {
    subnets = data.aws_subnets.available.ids
    security_groups = [aws_security_group.cockroachdb_sg.id]
  }
}

# EFS for CockroachDB data (persistent storage)
resource "aws_efs_file_system" "cockroachdb_data" {
  tags = {
    Name = "cockroachdb_data"
  }
}

resource "aws_efs_mount_target" "cockroachdb_data_mount" {
  count           = length(data.aws_availability_zones.available.names)
  file_system_id  = aws_efs_file_system.cockroachdb_data.id
  subnet_id       = tolist(data.aws_subnets.available.ids)[count.index]
  security_groups = [aws_security_group.cockroachdb_sg.id]
}

# IAM Role for EC2 instance to access ECS tasks
resource "aws_iam_role" "ec2_access_ecs_role" {
  name = "ec2_access_ecs_role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Effect = "Allow"
    }]
  })
}

# IAM Policy to provide necessary ECS permissions to the EC2 instance
resource "aws_iam_policy" "ec2_ecs_access_policy" {
  name        = "ec2_ecs_access_policy"
  description = "Allows EC2 instance to list and describe ECS tasks"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = [
        "ecs:ListTasks",
        "ecs:DescribeTasks"
      ],
      Resource = "*",
      Effect   = "Allow"
    }]
  })
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "ec2_ecs_access_policy_attachment" {
  role       = aws_iam_role.ec2_access_ecs_role.name
  policy_arn = aws_iam_policy.ec2_ecs_access_policy.arn
}

# Create an IAM instance profile which is required to assign a role to an EC2 instance
resource "aws_iam_instance_profile" "ec2_ecs_instance_profile" {
  name = "ec2_ecs_instance_profile"
  role = aws_iam_role.ec2_access_ecs_role.name
}

# EC2 instance configuration
resource "aws_instance" "rss_data_fetcher" {
  ami           = "ami-09ac7e749b0a8d2a1"
  instance_type = "t2.micro"
  key_name      = "my_ec2_key" # Replace with your SSH key name

  iam_instance_profile = aws_iam_instance_profile.ec2_ecs_instance_profile.name

  vpc_security_group_ids = [aws_security_group.ec2_ssh_sg.id]

user_data = <<-EOF
        #!/bin/bash
        yum update -y
        yum install -y python3 python3-pip git wget

        # Install CockroachDB client
        wget -qO- https://binaries.cockroachdb.com/cockroach-v21.1.9.linux-amd64.tgz | tar xvz
        sudo cp -i cockroach-v21.1.9.linux-amd64/cockroach /usr/local/bin/

        # Clone the frontend repo
        git clone https://github.com/Rss-Analyser/rss-frontend-repo.git /home/ec2-user/rss-frontend-repo

        # Clone the infrastructure repo
        git clone https://github.com/Rss-Analyser/rss-infrastructure-repo.git /home/ec2-user/rss-infrastructure-repo

        # Here, run the database setup script from the infrastructure repo.
        # Assuming the script is executable and contains the necessary logic 
        # to check if the database is set up, and if not, runs the setup.
        # Also assuming the script is located at the root of the repo.
        /home/ec2-user/rss-infrastructure-repo/setup_db_script.sh

        # Set up a cron job to run the rss_data_fetch_pipe.py script every hour
        (crontab -l 2>/dev/null; echo "0 * * * * /usr/bin/python3 /home/ec2-user/rss-frontend-repo/rss_data_fetch_pipe.py >> /home/ec2-user/rss_data_fetch_pipe.log 2>&1") | crontab -
        EOF

  tags = {
    Name = "rss_data_fetcher"
  }
}


# ALB Security Group
resource "aws_security_group" "alb_sg" {
  name        = "alb_sg"
  description = "Allow inbound traffic to ALB"

  # Allow inbound traffic on port 26257 (CockroachDB default)
  ingress {
    from_port   = 26257
    to_port     = 26257
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Adjust this based on your needs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Application Load Balancer
resource "aws_lb" "cockroachdb_alb" {
  name               = "cockroachdb-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = ["subnet-placeholder-1", "subnet-placeholder-2"] # Replace with your actual Subnet IDs

  enable_deletion_protection = false
  enable_cross_zone_load_balancing   = true
}

# Target Group for CockroachDB
resource "aws_lb_target_group" "cockroachdb_tg" {
  name     = "cockroachdb-tg"
  port     = 26257
  protocol = "TCP"
  vpc_id   = "vpc-placeholder" # Replace with your actual VPC ID

  health_check {
    interval            = 30
    port                = "26257"
    timeout             = 10
    protocol            = "TCP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

# ALB Listener
resource "aws_lb_listener" "cockroachdb_listener" {
  load_balancer_arn = aws_lb.cockroachdb_alb.arn
  port              = 26257
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cockroachdb_tg.arn
  }
}

# Update ECS Service to associate with the ALB
resource "aws_ecs_service" "cockroachdb" {
  # ... (existing configurations)

  load_balancer {
    target_group_arn = aws_lb_target_group.cockroachdb_tg.arn
    container_name   = "cockroachdb-container-name" # Replace with your container name in the task definition
    container_port   = 26257
  }

  # ... (rest of the configurations)
}
