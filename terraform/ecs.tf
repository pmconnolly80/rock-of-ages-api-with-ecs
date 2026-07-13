# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "rock-of-ages-cluster"

  tags = {
    Name = "rock-of-ages-cluster"
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "api" {
  family                   = "rock-of-ages-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"  # 0.25 vCPU
  memory                   = "512"  # 0.5 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${aws_ecr_repository.api.repository_url}:latest"
      essential = true

      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }

      environment = [
        {
          name  = "DB_HOST"
          value = aws_db_instance.rock_of_ages.address
        },
        {
          name  = "DB_NAME"
          value = aws_db_instance.rock_of_ages.db_name
        },
        {
          name  = "DB_USER"
          value = aws_db_instance.rock_of_ages.username
        },
        {
          name  = "DB_PASSWORD"
          value = var.db_password
        },
        {
          name  = "AWS_STORAGE_BUCKET_NAME"
          value = var.image_storage_bucket 
        },
        {
          name  = "AWS_REGION"
          value = var.aws_region
        }
      ]
    }
  ])
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "rock-of-ages-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = "${aws_ecr_repository.api.repository_url}:latest"
      essential = true
      command   = ["pipenv", "run", "python", "worker.py"]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }

      environment = [
        { name = "DB_HOST",                 value = aws_db_instance.rock_of_ages.address },
        { name = "DB_NAME",                 value = aws_db_instance.rock_of_ages.db_name },
        { name = "DB_USER",                 value = aws_db_instance.rock_of_ages.username },
        { name = "DB_PASSWORD",             value = var.db_password },
        { name = "AWS_STORAGE_BUCKET_NAME", value = var.image_storage_bucket },
        { name = "AWS_REGION",              value = var.aws_region },
        { name = "SQS_QUEUE_URL",           value = var.sqs_queue_url }
      ]
    }
  ])
}
# CloudWatch Log Group for ECS
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/rock-of-ages-api"
  retention_in_days = 7

  tags = {
    Name = "rock-of-ages-ecs-logs"
  }
}

# ECS Service
resource "aws_ecs_service" "api" {
  name            = "rock-of-ages-api-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 2  # Same as your 2 EC2 instances
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true  # Needed for Fargate tasks to pull from ECR
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api_tg.arn
    container_name   = "api"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.http_listener]

  tags = {
    Name = "rock-of-ages-api-service"
  }
}

resource "aws_ecs_service" "worker" {
  name            = "rock-of-ages-worker-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  tags = {
    Name = "rock-of-ages-worker-service"
  }
}
resource "aws_iam_role" "ecs_task_role" {
  name = "ecsTaskRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "ecs-task-role"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Policy that allows S3 access
resource "aws_iam_role_policy" "ecs_task_s3_policy" {
  name = "ecs-task-s3-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.image_storage_bucket}",
          "arn:aws:s3:::${var.image_storage_bucket}/*"
        ]
      },
      # ADD THIS BLOCK
      {
        Effect = "Allow"
        Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = var.sqs_queue_arn
      }
    ]
  })
}