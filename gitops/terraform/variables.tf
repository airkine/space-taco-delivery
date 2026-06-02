variable "github_token" {
  description = "GitHub personal access token with repo and admin:org scopes"
  type        = string
  sensitive   = true
}

variable "github_owner" {
  description = "GitHub organization or user that owns the repository"
  type        = string
}

variable "cosign_password" {
  description = "Password for the Cosign signing key (if using keyed signing)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sonar_token" {
  description = "SonarQube user token for the space-taco-delivery project"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sonar_host_url" {
  description = "Base URL of the self-hosted SonarQube instance (e.g. https://sonar.example.com)"
  type        = string
  default     = ""
}
