terraform {
  required_version = ">= 1.7"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Store state remotely in Azure Blob Storage
  # Authenticate via: az login, or set ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "terraformstate024"
    container_name       = "tfstate"
    key                  = "space-taco-delivery/github/terraform.tfstate"
  }
}

provider "github" {
  token = var.github_token
  owner = var.github_owner
}

# ---------------------------------------------------------------------------
# Repository
# ---------------------------------------------------------------------------
resource "github_repository" "space_taco" {
  name        = "space-taco-delivery"
  description = "🌮🚀 Intergalactic taco delivery microservice — GitOps practice repo"
  visibility  = "public"

  has_issues        = true
  has_projects      = false
  has_wiki          = false
  auto_init         = true
  allow_merge_commit = false
  allow_rebase_merge = false
  allow_squash_merge = true
  delete_branch_on_merge = true

  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"
}

# ---------------------------------------------------------------------------
# Main branch + default
# ---------------------------------------------------------------------------
resource "github_branch" "main" {
  repository = github_repository.space_taco.name
  branch     = "main"

  depends_on = [github_repository.space_taco]
}

resource "github_branch_default" "main" {
  repository = github_repository.space_taco.name
  branch     = github_branch.main.branch
}

# ---------------------------------------------------------------------------
# Branch protection for main
# ---------------------------------------------------------------------------
resource "github_branch_protection" "main" {
  repository_id = github_repository.space_taco.node_id
  pattern       = "main"

  required_status_checks {
    strict   = true
    contexts = ["Lint & Test", "Build & Publish"]
  }

  required_pull_request_reviews {
    dismiss_stale_reviews           = true
    require_code_owner_reviews      = true
    required_approving_review_count = 1
  }

  enforce_admins                  = false
  require_conversation_resolution = true
  require_signed_commits          = true
}

# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------
locals {
  labels = {
    "area/app"      = { color = "0075ca", description = "Application code changes" }
    "area/gitops"   = { color = "e4e669", description = "GitOps / Helm / Kyverno changes" }
    "area/infra"    = { color = "d93f0b", description = "Terraform / infrastructure changes" }
    "area/ci"       = { color = "1d76db", description = "CI/CD workflow changes" }
    "type/bug"      = { color = "ee0701", description = "Something is broken in the galaxy" }
    "type/feature"  = { color = "84b6eb", description = "A new taco offering" }
    "type/chore"    = { color = "fef2c0", description = "Maintenance work" }
    "type/security" = { color = "e11d48", description = "Security improvements" }
    "priority/high" = { color = "b60205", description = "High priority — taco emergency" }
    "priority/low"  = { color = "0e8a16", description = "Low priority — slow burn" }
  }
}

resource "github_issue_label" "labels" {
  for_each    = local.labels
  repository  = github_repository.space_taco.name
  name        = each.key
  color       = each.value.color
  description = each.value.description
}

# ---------------------------------------------------------------------------
# Secrets (values managed outside Terraform, referenced via vars)
# ---------------------------------------------------------------------------
resource "github_actions_secret" "cosign_password" {
  repository      = github_repository.space_taco.name
  secret_name     = "COSIGN_PASSWORD"
  plaintext_value = var.cosign_password
}

resource "github_actions_secret" "sonar_token" {
  repository      = github_repository.space_taco.name
  secret_name     = "SONAR_TOKEN"
  plaintext_value = var.sonar_token
}

resource "github_actions_secret" "sonar_host_url" {
  repository      = github_repository.space_taco.name
  secret_name     = "SONAR_HOST_URL"
  plaintext_value = var.sonar_host_url
}

# ---------------------------------------------------------------------------
# Environments
# ---------------------------------------------------------------------------
resource "github_repository_environment" "dev" {
  repository  = github_repository.space_taco.name
  environment = "dev"
}

data "github_user" "airkine" {
  username = "airkine"
}

resource "github_repository_environment" "prod" {
  repository  = github_repository.space_taco.name
  environment = "prod"

  reviewers {
    users = [data.github_user.airkine.id]
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}
