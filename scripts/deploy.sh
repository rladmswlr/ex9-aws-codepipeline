#!/bin/bash
# 1. 변수 설정
AWS_REGION="us-east-2"
ECR_REPOSITORY="nginx"
CONTAINER_NAME="nginx-app"

# 권한 힉득
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ECR_URI="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:latest"

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# 이미지(Docker) Pull
docker pull $ECR_URI

# 컨테이너 배포 ===============================================
# 컨테이너가존재할 경우에만 실행
docker stop $CONTAINER_NAME 2>/dev/null || true
docker rm $CONTAINER_NAME 2>/dev/null || true
docker run -d --name $CONTAINER_NAME -p 80:80 --restart always $ECR_URI

# 사용하지 않는 이미지 정리
docker image prune -f