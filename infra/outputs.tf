output "pipeline_role_arn" {
  description = "Put this in the GitHub Actions workflow (role-to-assume)."
  value       = module.iam.cicd_role_arns["github-terraform"]
}

output "permission_boundary_arn" {
  description = "Set as permissions_boundary on every role/user the pipeline creates."
  value       = module.iam.permission_boundary_arns["standard"]
}

output "oidc_provider_arns" {
  value = module.iam.oidc_provider_arns
}
