provider "aws" {
  region = "ap-southeast-2"
}

# Create a VPC to launch resources
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Get availability zones in the region
data "aws_availability_zones" "available" {}

# Create two public subnets across AZs
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

# Create an Internet Gateway for internet access
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# Create a route table for the public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

# Associate the route table with the subnets
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Group for ECS tasks and ALB
resource "aws_security_group" "ecs_sg" {
  name   = "ecs_sg"
  vpc_id = aws_vpc.main.id

  # Allow inbound HTTP traffic
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecr_repository" "app" {
  name         = "devops-demo"
  force_delete = true  # optional, to allow cleanup with terraform destroy
}

# Create an Application Load Balancer
resource "aws_lb" "app_lb" {
  name               = "devops-app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = aws_subnet.public[*].id
}

# Create a target group for the ALB
resource "aws_lb_target_group" "app_tg" {
  name         = "app-target-group"
  port         = 80
  protocol     = "HTTP"
  vpc_id       = aws_vpc.main.id
  target_type  = "ip"
}

# Create a listener on the ALB to forward requests to the target group
resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# Create an ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "devops-cluster"
  
}

# IAM role ECS tasks need to pull images and write logs
resource "aws_iam_role" "ecs_task_execution" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

# Attach ECS execution policy to the IAM role
resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Create ECR repository to store Docker images
resource "aws_ecr_repository" "app" {
  name = "devops-demo"
}

# Define ECS task using the Docker image from ECR
resource "aws_ecs_task_definition" "app" {
  family                   = "devops-app-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "devops-app",
      image     = "${aws_ecr_repository.app.repository_url}:latest",
      portMappings = [
        {
          containerPort = 80,
          hostPort      = 80
        }
      ]
    }
  ])
}

# Create ECS service to run and manage the task
resource "aws_ecs_service" "app" {
  name            = "devops-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = aws_subnet.public[*].id
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "devops-app"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.app_listener]
}
