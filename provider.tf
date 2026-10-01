provider "aws" {
  region  = "eu-west-3"
  #profile = "kops-project"
}
 
terraform {
  backend "s3" {
    bucket         = "kops-project"
    key            = "infra/terraform.tfstate"
    region         = "eu-west-3"
    #profile        = "kops-project"
    dynamodb_table = "terraform-locks"
    encrypt        = true
    #use_lockfile   = true
  }
}