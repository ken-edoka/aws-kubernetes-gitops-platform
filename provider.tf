provider "aws" {
  region  = "eu-west-3"
  #profile = "kops-project"
}
 
terraform {
  backend "s3" {
    bucket         = "kops-project-team-1"
    key            = "infra/terraform.tfstate"
    region         = "eu-west-3"
    #profile        = "kops-project"
    dynamodb_table = "terraform-locks-team1"
    encrypt        = true
    #use_lockfile   = true
  }
}