output "policy_arns" {
  description = "Managed policy ARNs, keyed by the key used in var.policies."
  value       = { for k, v in var.policies : k => aws_iam_policy.this["policy/${k}"].arn }
}

output "permission_boundary_arns" {
  description = "Permissions boundary ARNs, keyed by the key used in var.permission_boundaries."
  value       = { for k, v in var.permission_boundaries : k => aws_iam_policy.this["boundary/${k}"].arn }
}

output "group_arns" {
  value = { for k, g in aws_iam_group.this : k => g.arn }
}

output "user_arns" {
  value = { for k, u in aws_iam_user.this : k => u.arn }
}

output "role_arns" {
  description = "ARNs of all roles (general + CI/CD), keyed by role key."
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}

output "role_names" {
  value = { for k, r in aws_iam_role.this : k => r.name }
}

output "cicd_role_arns" {
  description = "ARNs of CI/CD roles only - the values you paste into pipeline config."
  value       = { for k in keys(var.cicd_roles) : k => aws_iam_role.this[k].arn }
}

output "instance_profile_names" {
  value = { for k, p in aws_iam_instance_profile.this : k => p.name }
}

output "oidc_provider_arns" {
  value = { for k, p in aws_iam_openid_connect_provider.this : k => p.arn }
}
