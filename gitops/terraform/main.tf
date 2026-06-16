terraform {
  required_version = ">= 1.7"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # fluxcd/flux provider bootstraps Flux into the AKS cluster and commits
    # the GitOps manifests to the repo — replaces running `flux bootstrap` manually.
    flux = {
      source  = "fluxcd/flux"
      version = "~> 1.4"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  # Store state remotely in Azure Blob Storage.
  # Authenticated via OIDC in CI (ARM_USE_OIDC=true + ARM_CLIENT_ID etc.).
  # Locally: az login is sufficient; the azurerm backend picks up the token automatically.
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

# features {} is required even when empty — the azurerm provider errors without it.
provider "azurerm" {
  features {}
  # Auth is handled by environment variables in CI (ARM_USE_OIDC, ARM_CLIENT_ID,
  # ARM_TENANT_ID, ARM_SUBSCRIPTION_ID) and by `az login` locally.
  # No credentials hardcoded here — they stay in CI secrets / local az login context.
  subscription_id = var.azure_subscription_id
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.main.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
}

# The flux provider talks to two surfaces: the Kubernetes API (to install Flux
# controllers) and GitHub (to commit the bootstrap manifests).  Both are wired
# from outputs of the AKS cluster resource so there is no manual kubeconfig step.
provider "flux" {
  kubernetes = {
    host = azurerm_kubernetes_cluster.main.kube_config[0].host

    # AKS returns base64-encoded certs in the kubeconfig block.
    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
  }
  git = {
    url = "https://github.com/${var.github_owner}/space-taco-delivery.git"
    http = {
      username = "git" # GitHub ignores the username for token auth
      password = var.github_token
    }
  }
}

# ---------------------------------------------------------------------------
# Repository
# ---------------------------------------------------------------------------
resource "github_repository" "space_taco" {
  name        = "space-taco-delivery"
  description = "🌮🚀 Intergalactic taco delivery microservice — GitOps practice repo"
  visibility  = "public"

  has_issues             = true
  has_projects           = false
  has_wiki               = false
  auto_init              = false
  allow_merge_commit     = false
  allow_rebase_merge     = false
  allow_squash_merge     = true
  delete_branch_on_merge = true

  squash_merge_commit_title   = "PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"
}

# ---------------------------------------------------------------------------
# Default branch
# ---------------------------------------------------------------------------
resource "github_branch_default" "main" {
  repository = github_repository.space_taco.name
  branch     = "main"
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

resource "github_actions_secret" "azure_client_id" {
  repository      = github_repository.space_taco.name
  secret_name     = "AZURE_CLIENT_ID"
  plaintext_value = var.azure_client_id
}

resource "github_actions_secret" "azure_tenant_id" {
  repository      = github_repository.space_taco.name
  secret_name     = "AZURE_TENANT_ID"
  plaintext_value = var.azure_tenant_id
}

resource "github_actions_secret" "azure_subscription_id" {
  repository      = github_repository.space_taco.name
  secret_name     = "AZURE_SUBSCRIPTION_ID"
  plaintext_value = var.azure_subscription_id
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
