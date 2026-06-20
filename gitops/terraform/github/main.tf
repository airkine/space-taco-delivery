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
# `value` is the current field (replaces deprecated `plaintext_value`).
# The provider encrypts it using the repository's GitHub public key before
# sending to the API — the plaintext never leaves Terraform's process unencrypted.
resource "github_actions_secret" "azure_client_id" {
  repository  = github_repository.space_taco.name
  secret_name = "AZURE_CLIENT_ID"
  value       = var.azure_client_id
}

resource "github_actions_secret" "azure_tenant_id" {
  repository  = github_repository.space_taco.name
  secret_name = "AZURE_TENANT_ID"
  value       = var.azure_tenant_id
}

resource "github_actions_secret" "azure_subscription_id" {
  repository  = github_repository.space_taco.name
  secret_name = "AZURE_SUBSCRIPTION_ID"
  value       = var.azure_subscription_id
}

# ---------------------------------------------------------------------------
# Environments
# ---------------------------------------------------------------------------
# Only ONE GitHub Environment exists in this repo: "dev". It is the gate the
# Terraform Apply jobs run under (see .github/workflows/terraform.yml and
# terraform-destroy.yml) — every apply, regardless of which branch triggered
# it, requires manual reviewer approval here before any infrastructure
# changes happen. There used to be a second "prod" environment used only for
# pushes to main, but maintaining two nearly-identical environments added
# confusion without adding safety (this repo has exactly one cluster/repo to
# protect), so it was removed and its reviewer/branch-policy settings were
# folded into "dev".
data "github_user" "airkine" {
  username = "airkine"
}

resource "github_repository_environment" "dev" {
  repository  = github_repository.space_taco.name
  environment = "dev"

  reviewers {
    users = [data.github_user.airkine.id]
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}
