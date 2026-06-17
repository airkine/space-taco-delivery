# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------

variable "github_token" {
  description = "GitHub personal access token with repo and admin:org scopes"
  type        = string
  # nullable = false prevents a caller from explicitly passing null to bypass
  # the "no default" requirement.
  nullable  = false
  sensitive = true
}

variable "github_owner" {
  description = "GitHub organization or user that owns the repository"
  type        = string
  nullable    = false
}

# ---------------------------------------------------------------------------
# Values passed through into github_actions_secret resources.
# These are infra credentials, but they live here (not in infra/) because the
# secret *resources* themselves are GitHub objects managed by this module.
# ---------------------------------------------------------------------------

variable "cosign_password" {
  description = "Password for the Cosign signing key (if using keyed signing)"
  type        = string
  # Block ordering: description → type → default → sensitive
  default   = ""
  sensitive = true
}

variable "azure_client_id" {
  description = "Azure App Registration client ID used for OIDC authentication in GitHub Actions"
  type        = string
  default     = ""

  # Prevent silent misconfiguration: if a value is supplied it must look like a UUID.
  validation {
    condition     = var.azure_client_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.azure_client_id))
    error_message = "azure_client_id must be a valid UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) or an empty string."
  }
}

variable "azure_tenant_id" {
  description = "Azure tenant ID"
  type        = string
  default     = ""

  validation {
    condition     = var.azure_tenant_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.azure_tenant_id))
    error_message = "azure_tenant_id must be a valid UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) or an empty string."
  }
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
  default     = ""

  validation {
    condition     = var.azure_subscription_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.azure_subscription_id))
    error_message = "azure_subscription_id must be a valid UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) or an empty string."
  }
}
