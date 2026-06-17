# provider.tf — Provider configuration blocks only.
# Version constraints and the backend live in versions.tf.

provider "github" {
  token = var.github_token
  owner = var.github_owner
}
