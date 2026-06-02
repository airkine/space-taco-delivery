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
