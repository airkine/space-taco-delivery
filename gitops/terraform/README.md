# Space Taco Delivery — Terraform

This Terraform configuration manages the GitHub repository for `space-taco-delivery` — including branch protection, issue labels, environments, and Actions secrets.

## What it builds

| Resource | Details |
|----------|---------|
| `github_repository` | Private repo named `space-taco-delivery` with squash-merge only, auto branch deletion, issues enabled |
| `github_branch_protection` | Protects `main`: requires passing CI (`Lint & Test`, `Build & Publish`), 1 approving review, signed commits, conversation resolution |
| `github_issue_label` | 10 labels across `area/`, `type/`, and `priority/` prefixes |
| `github_actions_secret` | `COSIGN_PASSWORD` secret for container image signing |
| `github_repository_environment` | `dev` environment (unprotected) and `prod` environment (requires reviewer approval, protected branches only) |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7
- A GitHub account with permission to create repositories in the target org/user
- A GitHub personal access token (PAT) — see [Secrets](#secrets) below

## Secrets

Three variables are required. **Never commit real values to source control.**

| Variable | Description | Sensitive |
|----------|-------------|-----------|
| `github_token` | GitHub PAT with `repo` and `admin:org` scopes | Yes |
| `github_owner` | GitHub org or username that will own the repo | No |
| `cosign_password` | Cosign signing key password — leave empty if using keyless signing | Yes |

### Option 1 — `terraform.tfvars` (local dev)

Copy the example file and fill in your values:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
github_token    = "ghp_xxxxxxxxxxxxxxxxxxxx"
github_owner    = "your-org-or-username"
cosign_password = ""  # leave empty for keyless signing
```

`terraform.tfvars` is gitignored — it will not be committed.

### Option 2 — Environment variables

Prefix any variable with `TF_VAR_` to pass it without a tfvars file:

```bash
export TF_VAR_github_token="ghp_xxxxxxxxxxxxxxxxxxxx"
export TF_VAR_github_owner="your-org-or-username"
export TF_VAR_cosign_password=""
```

### GitHub PAT scopes required

When creating the token at [github.com/settings/tokens](https://github.com/settings/tokens):

- `repo` — full repository access
- `admin:org` → `write:org` — needed to manage org-level settings and environments
- `delete_repo` — only needed if you plan to run `terraform destroy`

## State backend

State is stored remotely in Azure Blob Storage. Update the backend block in `main.tf` with your values before running `init`:

```hcl
backend "azurerm" {
  resource_group_name  = "your-rg"
  storage_account_name = "yourstorageaccount"
  container_name       = "tfstate"
  key                  = "space-taco-delivery/github/terraform.tfstate"
}
```

### Backend authentication

The azurerm backend picks up credentials in this order:

1. **Azure CLI** (recommended for local dev) — run `az login` before `terraform init`
2. **Service principal env vars** — set before running any Terraform command:
   ```bash
   export ARM_CLIENT_ID="00000000-0000-0000-0000-000000000000"
   export ARM_CLIENT_SECRET="your-client-secret"
   export ARM_TENANT_ID="00000000-0000-0000-0000-000000000000"
   export ARM_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
   ```

The storage account and container must exist before running `terraform init` — Terraform does not create the backend resources. Create them once with:

```bash
az group create --name your-rg --location eastus
az storage account create --name yourstorageaccount --resource-group your-rg --sku Standard_LRS
az storage container create --name tfstate --account-name yourstorageaccount
```

If you want to run locally without a remote backend, remove the `backend` block entirely — Terraform will use local state.

## Running Terraform

All commands run from this directory (`gitops/terraform/`).

### 1. Initialize

Downloads the GitHub provider and configures the backend:

```bash
terraform init
```

### 2. Validate and format check

```bash
terraform fmt -check -recursive
terraform validate
```

### 3. Plan

Preview what will be created before applying:

```bash
terraform plan
```

### 4. Apply

Create the resources:

```bash
terraform apply
```

Review the plan output and type `yes` to confirm.

### 5. Outputs

After apply, Terraform prints the repo URLs:

```
repo_clone_url = "https://github.com/your-org/space-taco-delivery.git"
repo_ssh_url   = "git@github.com:your-org/space-taco-delivery.git"
repo_full_name = "your-org/space-taco-delivery"
```

Retrieve them any time with:

```bash
terraform output
```

## Destroy

To tear down all managed resources:

```bash
terraform destroy
```

This will delete the GitHub repository and everything in it. Requires the `delete_repo` PAT scope.
