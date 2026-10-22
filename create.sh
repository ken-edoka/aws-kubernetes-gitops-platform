#!/bin/bash
 
# Variables
PROFILE="default"
REGION="eu-west-3"
 
DYNAMO_TABLE="terraform-locks"
S3_BUCKET="kops-project"
 
echo "Creating DynamoDB table for state locking..."
aws dynamodb create-table \
    --table-name $DYNAMO_TABLE \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
    --region $REGION \
    --profile $PROFILE \
    2>/dev/null || echo "DynamoDB table may already exist."
 
echo "Creating S3 bucket for remote state..."
aws s3api create-bucket \
    --bucket $S3_BUCKET \
    --region $REGION \
    --create-bucket-configuration LocationConstraint=$REGION \
    --profile $PROFILE \
    2>/dev/null || echo "S3 bucket may already exist."
 
echo "Enabling versioning on S3 bucket..."
aws s3api put-bucket-versioning \
    --bucket $S3_BUCKET \
    --versioning-configuration Status=Enabled \
    --profile $PROFILE
 
echo "Setup complete. S3 bucket '$S3_BUCKET' ready with versioning, DynamoDB table '$DYNAMO_TABLE' ready for state locking."
