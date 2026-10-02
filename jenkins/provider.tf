provider "aws" {
  region = "eu-west-3"
  #profile = "default"
}

terraform {
  backend "s3" {
    bucket = "kops-project"
    key    = "jenkins/terraform.tfstate"
    region = "eu-west-3"
    #profile        = "default"
    encrypt = true
    #use_lockfile   = true
  }
}