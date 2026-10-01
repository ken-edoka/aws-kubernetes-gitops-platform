variable "vpc_tags" {
  description = "Tags used to look up the existing VPC."
  type        = map(string)
  default = {
    Name = "kops-vpc"
  }
}
 
variable "subnet_tags" {
  description = "Tags used to look up the existing subnet."
  type        = map(string)
  default = {
    Name = "kops-public-subnet-1"
  }
}
 
variable "istio_version" {
  description = "Version of Istio to install."
  type        = string
  default     = "1.20.2"
}
 
variable "repo_url" {
  description = "URL of the Helm repository for Istio charts."
  type        = string
  default     = "https://istio-release.storage.googleapis.com/charts"
}
 
variable "namespace" {
  description = "Kubernetes namespace to install Istio into."
  type        = string
  default     = "istio-system"
}
 
variable "github_username" {
  description = "GitHub username for Argo CD repository access."
  type        = string
  sensitive   = true
}
 
variable "github_password" {
  description = "GitHub password or personal access token for Argo CD repository access."
  type        = string
  sensitive   = true
}
 