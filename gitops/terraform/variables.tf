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
  description = "SonarQube user token — generate at My Account → Security on your SonarQube instance"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sonar_host_url" {
  description = "Base URL of the self-hosted SonarQube instance (e.g. https://sonar.example.com)"
  type        = string
  default     = ""
}

variable "azure_client_id" {
  description = "Azure App Registration client ID used for OIDC authentication in GitHub Actions"
  type        = string
  default     = ""
}

variable "azure_tenant_id" {
  description = "Azure tenant ID"
  type        = string
  default     = ""
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
  default     = ""
}
