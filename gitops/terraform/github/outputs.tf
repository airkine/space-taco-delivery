output "repo_clone_url" {
  description = "HTTPS clone URL"
  value       = github_repository.space_taco.http_clone_url
}

output "repo_ssh_url" {
  description = "SSH clone URL"
  value       = github_repository.space_taco.ssh_clone_url
}

output "repo_full_name" {
  description = "Full repository name (org/repo)"
  value       = github_repository.space_taco.full_name
}
