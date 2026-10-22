#!/bin/bash
 
# If invoked with sh (which may not support bash-only syntax), re-exec with bash.
if [ -z "$BASH_VERSION" ]; then
  exec bash "$0" "$@"
fi
 
# =========================================
# Script: destroy_remote_state.sh
# Purpose: Delete DynamoDB table & S3 bucket used for Terraform remote state
# =========================================
 
set -o pipefail
 
# variables
PROFILE="default"
REGION="eu-west-3"
S3_BUCKET="kops-project"
DYNAMO_TABLE="terraform-locks"
 
# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
 
# Error handling
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}
 
success_msg() {
    echo -e "${GREEN}✓ $1${NC}"
}
 
warn_msg() {
    echo -e "${YELLOW}⚠ $1${NC}"
}
 
# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
   
    if ! command -v aws &> /dev/null; then
        error_exit "AWS CLI is not installed"
    fi
   
    if ! command -v jq &> /dev/null; then
        error_exit "jq is not installed"
    fi
   
    # Verify AWS profile exists
    if ! aws configure get region --profile $PROFILE &> /dev/null; then
        error_exit "AWS profile '$PROFILE' not found or not configured"
    fi
   
    success_msg "Prerequisites check passed"
}
 
# Check if bucket exists
bucket_exists() {
    aws s3api head-bucket --bucket $S3_BUCKET --profile $PROFILE --region $REGION 2>/dev/null
    return $?
}
 
# Delete S3 versions
delete_s3_versions() {
    echo "Deleting all versions in S3 bucket..."
   
    if ! bucket_exists; then
        warn_msg "S3 bucket '$S3_BUCKET' does not exist"
        return 0
    fi
   
    local version_count=0
    local delete_count=0
   
    while IFS= read -r line; do
        local key=$(echo "$line" | jq -r '.Key')
        local version=$(echo "$line" | jq -r '.VersionId')
       
        if [ ! -z "$key" ] && [ ! -z "$version" ] && [ "$key" != "null" ] && [ "$version" != "null" ]; then
            ((version_count++))
            if aws s3api delete-object \
                --bucket "$S3_BUCKET" \
                --key "$key" \
                --version-id "$version" \
                --profile "$PROFILE" \
                --region "$REGION" &>/dev/null; then
                ((delete_count++))
            else
                warn_msg "Failed to delete version: $key"
            fi
        fi
    done < <(aws s3api list-object-versions \
        --bucket "$S3_BUCKET" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json 2>/dev/null | jq -c '.Versions[]? // empty')
   
    if [ $delete_count -gt 0 ]; then
        success_msg "Deleted $delete_count object versions"
    elif [ $version_count -eq 0 ]; then
        echo "No object versions found to delete"
    fi
}
 
# Delete S3 delete markers
delete_s3_markers() {
    echo "Deleting all delete markers in S3 bucket..."
   
    if ! bucket_exists; then
        return 0
    fi
   
    local marker_count=0
    local delete_count=0
   
    while IFS= read -r line; do
        local key=$(echo "$line" | jq -r '.Key')
        local version=$(echo "$line" | jq -r '.VersionId')
       
        if [ ! -z "$key" ] && [ ! -z "$version" ] && [ "$key" != "null" ] && [ "$version" != "null" ]; then
            ((marker_count++))
            if aws s3api delete-object \
                --bucket "$S3_BUCKET" \
                --key "$key" \
                --version-id "$version" \
                --profile "$PROFILE" \
                --region "$REGION" &>/dev/null; then
                ((delete_count++))
            else
                warn_msg "Failed to delete marker: $key"
            fi
        fi
    done < <(aws s3api list-object-versions \
        --bucket "$S3_BUCKET" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json 2>/dev/null | jq -c '.DeleteMarkers[]? // empty')
   
    if [ $delete_count -gt 0 ]; then
        success_msg "Deleted $delete_count delete markers"
    elif [ $marker_count -eq 0 ]; then
        echo "No delete markers found to delete"
    fi
}
 
# Delete S3 bucket
delete_s3_bucket() {
    echo "Deleting S3 bucket..."
   
    if ! bucket_exists; then
        warn_msg "S3 bucket '$S3_BUCKET' does not exist"
        return 0
    fi
   
    # Final check for any remaining objects
    local remaining=$(aws s3api list-object-versions \
        --bucket "$S3_BUCKET" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --output json 2>/dev/null | jq '[.Versions[]?, .DeleteMarkers[]?] | length')
   
    if [ "$remaining" -gt 0 ]; then
        error_exit "S3 bucket still contains $remaining objects/markers. Cleanup may have failed."
    fi
   
    local output
    output=$(aws s3api delete-bucket \
        --bucket "$S3_BUCKET" \
        --region "$REGION" \
        --profile "$PROFILE" 2>&1)
   
    if [ $? -eq 0 ]; then
        success_msg "S3 bucket '$S3_BUCKET' deleted"
    else
        error_exit "Failed to delete S3 bucket: $output"
    fi
}
 
# Delete DynamoDB table
delete_dynamodb_table() {
    echo "Deleting DynamoDB table..."
   
    # Check if table exists
    if ! aws dynamodb describe-table \
        --table-name $DYNAMO_TABLE \
        --region $REGION \
        --profile $PROFILE &>/dev/null; then
        warn_msg "DynamoDB table '$DYNAMO_TABLE' does not exist"
        return 0
    fi
   
    if aws dynamodb delete-table \
        --table-name $DYNAMO_TABLE \
        --region $REGION \
        --profile $PROFILE 2>/dev/null; then
        success_msg "DynamoDB table '$DYNAMO_TABLE' deleted"
    else
        error_exit "Failed to delete DynamoDB table '$DYNAMO_TABLE'"
    fi
}
 
# Main execution
main() {
    echo "======================================="
    echo "Terraform Remote State Cleanup"
    echo "======================================="
    echo ""
   
    check_prerequisites || exit 1
    echo ""
   
    delete_s3_versions
    delete_s3_markers
    delete_s3_bucket
    delete_dynamodb_table
   
    echo ""
    echo "======================================="
    success_msg "Cleanup completed successfully!"
    echo "======================================="
}
 
main "$@"