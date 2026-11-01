variable "name_prefix" {
  description = "Prefix applied to the names of roles, groups and policies e.g 'cob-dev-'. Users are not prefixed"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}

variable "default_permissions_boundary_arn" {
  description = "Boundary applied to every role/user that does not set its own."
  type        = string
  default     = null
}

# Managed policies
variable "policies" {
  description = <<-EOT
    Customer managed policies, keyed by short name. Provide either 'statements'(through aws_iam_policy_document)
    or a raw 'policy_json'.
  EOT
  type = map(object({
    description = optional(string, "Managed by Terraform")
    path        = optional(string, "/")
    policy_json = optional(string)
    statements = optional(list(object({
      sid           = optional(string)
      effect        = optional(string, "Allow")
      actions       = optional(list(string))
      not_actions   = optional(list(string))
      resources     = optional(list(string))
      not_resources = optional(list(string))
      conditions = optional(list(object({
        test     = string
        variable = string
        values   = list(string)
      })), [])
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for p in values(var.policies) : p.policy_json != null || length(p.statements) > 0
    ])
    error_message = "Each policy needs either policy_json or at least one statement."
  }
}

variable "permission_boundaries" {
  description = "Managed policies intended to be used as permissions boundaries. Same shape as policies. Reference them vis permission_boundary_key."
  type = map(object({
    description = optional(string, "Permission boundary managed by Terraform")
    path        = optional(string, "/boundaries/")
    policy_json = optional(string)
    statements = optional(list(object({
      sid           = optional(string)
      effect        = optional(string, "Allow")
      actions       = optional(list(string))
      not_actions   = optional(list(string))
      resources     = optional(list(string))
      not_resources = optional(list(string))
      conditions = optional(list(object({
        test     = string
        variable = string
        values   = list(string)
      })), [])
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for p in values(var.permission_boundaries) : p.policy_json != null || length(p.statements) > 0
    ])
    error_message = "Each permision boundary needs either policy_json or at least one statement"
  }
}


# Groups & Users
variable "groups" {
  description = "IAM groups. 'policy_keys' reference var.policies; 'policy_arns' are existing/AWS-managed policies"
  type = map(object({
    path        = optional(string, "/")
    policy_keys = optional(list(string), [])
    policy_arns = optional(list(string), [])
  }))
  default = {}
}

variable "users" {
  description = "IAM users keyed by username. 'groups' reference keys of the var.groups. No access keys or console passwords are created here."
  type = map(object({
    path                    = optional(string, "/")
    groups                  = optional(list(string), [])
    policy_keys             = optional(list(string), [])
    policy_arns             = optional(list(string), [])
    permission_boundary_key = optional(string)
    permission_boundary_arn = optional(string)
    force_destroy           = optional(bool, false)
    tags                    = optional(map(string), {})
  }))
  default = {}
}

# Roles (service + cross-account)
variable "roles" {
  description = <<-EOT
  General-purpose roles.
    - Cross-service: set 'trusted_services' (e.g ["lambda.amazonaws.com"]).
    - Cross-account: set 'trusted_aws_principals' (account IDs or ARNs), plus 'external_id' and/or 'require_mfa'.
    - Anything exotic: pass 'assume_role_policy_json' and the trust fields are ignored.
  EOT
  type = map(object({
    description             = optional(string, "Managed by Terraform")
    path                    = optional(string, "/")
    max_session_duration    = optional(number, 3600)
    trusted_services        = optional(list(string), [])
    trusted_aws_principals  = optional(list(string), [])
    external_id             = optional(string)
    require_mfa             = optional(bool, false)
    assume_role_policy_json = optional(string)
    policy_keys             = optional(list(string), [])
    policy_arns             = optional(list(string), [])
    permission_boundary_key = optional(string)
    permission_boundary_arn = optional(string)
    create_instance_profile = optional(bool, false)
    tags                    = optional(map(string), {})
  }))
  default = {}
}

# CI/CD
variable "oidc_providers" {
  description = "OIDC identity providers to create (e.g GitHub Actions, Gitlab). Skip if the provider already exists and use 'oidc_provider_arn' on the CI/CD role instead."
  type = map(object({
    url             = string
    client_id_list  = list(string)
    thumbprint_list = optional(list(string), [])
  }))
  default = {}
}

variable "cicd_roles" {
  description = <<-EOT
  Pipeline roles.
    - OIDC (Github Actions/Gitlab): set 'oidc_provider_key' (created here) or 'oidc_provider_arn' (already existing)
      and 'subjects' (the 'sub' claim patterns allowed to assume, e.g. "repo:my-org/my-repo:refs/heads/main").
    - AWS-native (CodeBuild/CodePipeline/CodeDeploy): set 'trusted_services'.
  EOT
  type = map(object({
    description             = optional(string, "CI/CD role managed by Terraform")
    path                    = optional(string, "/cicd/")
    max_session_duration    = optional(number, 3600)
    oidc_provider_key       = optional(string)
    oidc_provider_arn       = optional(string)
    subjects                = optional(list(string), [])
    audiences               = optional(list(string), ["sts.amazonaws.com"])
    trusted_services        = optional(list(string), [])
    policy_keys             = optional(list(string), [])
    policy_arns             = optional(list(string), [])
    permissions_boundary_key = optional(string)
    permissions_boundary_arn = optional(string)
    tags                    = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for r in values(var.cicd_roles) : !contains(r.subjects, "*")])
    error_message = "A bare \"*\" OIDC subject  lets any repo assume the role. Scope subjects to a specific org/repo/branch."
  }

  validation {
    condition = alltrue([
      for r in values(var.cicd_roles) :
      (r.oidc_provider_key != null || r.oidc_provider_arn != null) ? length(r.subjects) > 0 : true
    ])
    error_message = "OIDC CI/CD roles must define at least one subject."
  }
}