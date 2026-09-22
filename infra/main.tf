terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source = "hashicorp/random"
    }
  }

  backend "s3" {
    bucket         = "std16-test-bucket"
    key            = "terraformState/Ex/ex9-aws-codepipeline/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "std16-lab-lock-table"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-2"
}

# ###########################################################
# 테라폼 기능 설정
# ===================================================================
# 키페어 / AMI / 보안그룹 / 서브넷ID /

variable "key_name" {
  description = "키페어 이름"
  type        = string
  default     = "std16-keypair"
}

variable "owner" {
  description = "사용자 계정 이름"
  type        = string
  default     = "std16"
}

variable "environment" {
  description = "프로젝트 역할 구분"
  type        = string
  default     = "ex"
}

variable "default_version" {
  description = ""
  type        = string
  default     = "latest" # 특정 버전을 지정하고자 할 경우 문자열 형태의 숫자 기제

}

locals {
  key_name = var.key_name

  tag_header = var.owner != "" && var.environment != "" ? "${var.owner}-${var.environment}-" : (
    var.owner != "" ? "${var.owner}-" : ""
  )

  vpc_id              = data.aws_vpc.vpc.id
  ami_id              = data.aws_ami.al2023.id
  security_groups_ids = data.aws_security_groups.security_groups.ids
  ec2_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]
}

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["${local.tag_header}vpc"]
  }
}

# Amazon Linux 2023 최신 AMI 조회
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ####################################################
# Security Groups
# ===================================================

# 외부 ALB용 Security Group
resource "aws_security_group" "external_alb_sg" {
  name        = "${local.tag_header}external-alb-sg"
  description = "External ALB Security Group"
  vpc_id      = local.vpc_id

  # HTTP 접속 허용
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 외부 통신 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.tag_header}external-alb-sg"
  }
}

# SSH 접속용 Security Group
resource "aws_security_group" "ssh_sg" {
  name        = "${local.tag_header}ssh-sg"
  description = "SSH Security Group"
  vpc_id      = local.vpc_id

  # 실습용 SSH 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 외부 통신 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.tag_header}ssh-sg"
  }
}

data "aws_security_groups" "security_groups" {
  filter {
    name = "tag:Name"
    values = [
      "${local.tag_header}external-alb-sg",
      "${local.tag_header}ssh-sg"
    ]
  }
}

# 적용방법 : vpc_security_group_ids = [data...id, data.....id]
# ALB 보안그룹
# data "aws_security_group" "security_group_alb" {
#   filter {
#     name = "tag:Name"
#     values = [
#       "${local.tag_header}external-alb-sg"
#     ]
#   }
# }

# #SSH 보안그룹
# data "aws_security_group" "security_group_ssh" {
#   filter {
#     name = "tag:Name"
#     values = [
#       "${local.tag_header}ssh-sg"
#     ]
#   }
# }

output "information" {
  value = [
    local.vpc_id,
    data.aws_security_groups.security_groups.ids
  ]
}
# #######################################################################
# 인스턴스에 부여할 역할
# =====================================================================
resource "aws_iam_role" "node_role_asg" {
  name = "${local.tag_header}AmazonASGNodeEC2-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole" # 신뢰관계 허용(IAM Role을 임시로 획득하여 권한을 행사, 임시권한 허용)
      }
    ]
  })
}

# 정책 연결
resource "aws_iam_role_policy_attachment" "node_policies_asg" {
  for_each = toset(local.ec2_policy_arns)

  role       = aws_iam_role.node_role_asg.name
  policy_arn = each.value
}

# 인스턴스 프로필 생성
resource "aws_iam_instance_profile" "node_profile_asg" {
  name = "${local.tag_header}ASGNodeInstance-profile"
  role = aws_iam_role.node_role_asg.name
}

# ================================================================================
# CodeDeploy 역할(Role)
# --------------------------------------------------------------------------------
# 역할 생성
resource "aws_iam_role" "codedeploy_role" {
  name = "${local.tag_header}AmazonCodeDeployService-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole" # IAM Role을 임시로 획득하여 권한을 행사할 수 있도록 허용
    }]
  })
}

# 관리형 정책을 역할에 연결
resource "aws_iam_role_policy_attachment" "codedeploy_policy" {
  role       = aws_iam_role.codedeploy_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# =========================================================================
# CodePipeline 서비스 에서 사용할 IAM Role 생성
# ----------------------------------------------------------------------
resource "aws_iam_role" "codepipeline_role" {
  name = "${local.tag_header}AmazonCodePipelineService-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole" # IAM Role을 임시로 획득하여 권한을 행사할 수 있도록 허용
    }]
  })
}

# 각 서비스에 대한 접근권한(정책) 생성
resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "${local.tag_header}CodePipelineServicePolicy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObjectAcl",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:PutObject",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:GetDeployment",
          "codedeploy:GetDeploymentConfig",
          "codedeploy:RegisterApplicationRevision",
        ]
        Resource = "*"
      }
    ]
  })
}

# ####################################################
# Pipeline 저장용 S3 Bucket
# ===================================================
# byte_length에 정의된 자릿수의 양의 숫자 반환
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Pipeline 구성에 필요한 배포 파일 저장소 생성
resource "aws_s3_bucket" "pipeline_bucket" {
  bucket        = "${local.tag_header}pipeline-bucket-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${local.tag_header}pipeline-bucket-${random_id.bucket_suffix.hex}"
  }
}

# 생성된 버킷의 버전관리 활성화(CodePipeline에서 필수 속성)
resource "aws_s3_bucket_versioning" "pipeline_bucket_versioning" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  versioning_configuration {
    status = "Enabled"
  }

}

# 퍼블릭 엑세스 전체 차단 (보안 규정 준수)
resource "aws_s3_bucket_public_access_block" "pipeline_bucket_public_access" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
# 서버 측 기본 암호화
resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_bucket_encryption" {
  bucket = aws_s3_bucket.pipeline_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# #############################################################################
# 서비스에 사용할 역할 생성
# =============================================================================



# #############################################################################
# Launch Template & UserData
# =============================================================================
# 템플릿 생성
resource "aws_launch_template" "asg_lt" {
  name_prefix            = "${local.tag_header}asg-launch-template-"
  image_id               = local.ami_id # data.aws_ami.a12023.id
  instance_type          = "t3.small"
  key_name               = local.key_name
  vpc_security_group_ids = local.security_groups_ids
  #   vpc_security_group_ids = [
  #     data.aws_security_group.external_alb_sg.id,
  #     data.aws_security_group.ssh_sg.id  
  #   ]

  # 기본 버전 지정 방법 ----------------------------------------
  update_default_version = var.default_version == "latest" ? true : false
  default_version        = var.default_version != "latest" ? tostring(var.default_version) : null
  # ---------------------------------------------------------
  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile_asg.name
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              dnf update -y
              # ruby: CodeDeploy서비스 개발 언어, codedeploy-agent 설치를 위해 반드시 필요
              dnf install -y ruby wget docker

              systemctl start docker
              systemctl enable docker
              usermod -aG docker ec2-user

              cd /tmp
              wget https://aws-codedeploy-us-east-2.s3.us-east-2.amazonaws.com/latest/install
              chmod +x ./install
              ./install auto

              systemctl start codedeploy-agent
              systemctl enable codedeploy-agent
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.tag_header}asg-node-instance"
    }
  }
}

# ###########################################################
# Auto Scaling Group
# ============================================================
data "aws_subnets" "target_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.vpc.id]
  }

  filter {
    name   = "tag:Type"
    values = ["private"]
  }
}

resource "aws_autoscaling_group" "asg" {
  name             = "${local.tag_header}codedeploy-asg"
  min_size         = 1
  max_size         = 3
  desired_capacity = 2

  vpc_zone_identifier = data.aws_subnets.target_subnets.ids

  launch_template {
    id      = aws_launch_template.asg_lt.id
    version = "$Latest"
  }
}

# ####################################################################
# CodeDeploy Application & Deployment Group
# ====================================================================
resource "aws_codedeploy_app" "app" {
  name = "${local.tag_header}asg-codedeploy-app"
  # 배포 대상 정의: Server / Lambda / ECS
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "dg" {
  deployment_group_name = "${local.tag_header}asg-deployment-group"

  #codedeploy_app리소스 이름
  app_name = aws_codedeploy_app.app.name

  # codedeploy서비스에 추가해줄 영향(Role)
  service_role_arn = aws_iam_role.codedeploy_role.arn

  # 배포 대상 정의
  autoscaling_groups = [aws_autoscaling_group.asg.name]

  # 배포 전략(구성) 지정
  # "CodeDeployDefauit.AllAtOnce": 타겟 인스턴스 전체에 동시에 한 번에 배포하는 방식
  #                                 ( 전체 중단 --> 동시 배포 --> 동시 재시작 )

  deployment_config_name = "CodeDeployDefault.AllAtOnce"
}

# #######################################################################
# 연결 리소스 생성 및 CodePipeline 리소스 생성
# =======================================================================
# AWS - GitHub 간 CodeStar Connection 생성
# -----------------------------------------------------------------------
resource "aws_codestarconnections_connection" "github" {
  name          = "${local.tag_header}github-connection"
  provider_type = "GitHub"
}

# ======================================================================
# AWS CodePiipeline 생성
# ----------------------------------------------------------------------
resource "aws_codepipeline" "codepipeline" {
  name = "${local.tag_header}asg-cicd-pipeline"

  # CodePipeline Role 정의
  role_arn = aws_iam_role.codepipeline_role.arn

  # 소스코드 정보
  artifact_store {
    # 앞서 생성한 Pipeline 전용 s3버킷 이름지정
    location = aws_s3_bucket.pipeline_bucket.bucket

    # 아티팩트 저장소 유형 지정(S3 사용)
    type = "S3"
  }
  # --------------------------------------------------------------------------
  # Stage 1: Source
  # ------------------------------------------------------------------
  stage {
    name = "Source"
    action {
      name     = "Source"
      category = "Source"
      owner    = "AWS"                      # 액션 제공자(AWS에서 제공하는 서비스 활용)
      provider = "CodeStarSourceConnection" # GitHub V2액션과 변동 표준인 "CodeStarSourceConnection" 사용
      version  = "1"

      # ZIP 소스 압축파일을 다음 스테이지로 전달할 전달용 아티팩트 이름 선언
      output_artifacts = ["source_output"]

      # GitHub 연동을 위한 속성값 정의
      configuration = {
        # GitHub와 CodeDeploy를 연결하는 연결 객체 정의
        ConnectionArn = aws_codestarconnections_connection.github.arn
        # GitHub Repository 이름
        FullRepositoryId = "rladmswlr/ex9-aws-codepipeline"
        # 브랜치 정의
        BranchName = "main"
      }
    }
  }

  # --------------------------------------------------------------------------
  # Stage 2: Deploy
  # ------------------------------------------------------------------
  stage {
    name = "Deploy"
    action {
      name     = "Deploy"
      category = "Deploy"
      owner    = "AWS"        # 액션 제공자(AWS에서 제공하는 서비스 활용)
      provider = "CodeDeploy" # GitHub V2액션과 변동 표준인 "CodeStarSourceConnection" 사용
      version  = "1"

      # ZIP 소스 압축파일을 다음 스테이지로 전달할 전달용 아티팩트 이름 선언, 된것을 받겠다.
      input_artifacts = ["source_output"] # Stage 1의 output_artifacts에 정의된 이름

      # GitHub 연동을 위한 속성값 정의
      configuration = {
        # 배포서비스 (CodeDeploy Application) 이름
        ApplicationName = aws_codedeploy_app.app.name
        # 배포를 진행할 CodeDeploy Deployment Graoup 이름
        DeploymentGroupName = aws_codedeploy_deployment_group.dg.deployment_group_name
      }
    }
  }

}
