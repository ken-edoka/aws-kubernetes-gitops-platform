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
 