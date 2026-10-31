locals {
  policy_defs = merge(
    { for k, v in var.var.policies : "policy/${k}" => v },
    { for k, v in var.permission_boundaries : "boundary/${k}" => v }
  )

  policy_arns = { for k, p in aws_iam_policy.this : k => p.arn }

  #   OIDC info per CI/CD role
  oidc_info = {
    for k, r in var.var.cicd_roles : k => {
      arn  = r.oidc_provider_key != null ? aws_iam_openid_connect_provider.this[r.oidc_provider_key].arn : r.oidc_provider_arn
      host = r.oidc_provider_key != null ? replace(var.var.oidc_providers[r.oidc_provider_key].url, "https://", "") : regex("oidc-provider/(.+)$", r.oidc_provider_arn)[0]
    } if r.oidc_provider_key != null || r.oidc_provider_arn != null
  }

  #   Trust policies
  role_trust = {
    for k, r in var.roles : k => (
      r.assume_role_policy_json != null ? r.assume_role_policy_json : jsonencode({
        Version = "2012-10-17"
        Statement = concat(
          length(r.trusted_services) > 0 ? [{
            Effect    = "Allow"
            Principal = { Service = r.trusted_services }
            Action    = "sts:AssumeRole"
          }] : [],
          length(r.trusted_aws_principals) > 0 ? [merge(
            {
              Effect    = "Allow"
              Principal = { AWS = r.trusted_aws_principals }
              Action    = "sts:AssumeRole"
            },
            (r.external_id != null || r.require_mfa) ? {
              Condition = merge(
                r.external_id != null ? { StringEquals = { "sts:ExternalId" = r.external_id } } : {},
                r.require_mfa ? { Bool = { "aws:MultiFactorAuthPresent" = "true" } } : {},
              )
            } : {}
          )] : [],
        )
      })
    )
  }

  cicd_trust = {
    for k, r in var.cicd_roles : k => jsonencode({
      Version = "2012-10-17"
      Statement = concat(
        contains(keys(local.oidc_info), k) ? [{
          Effect    = "Allow"
          Principal = { Federated = local.oidc_info[k].arn }
          Action    = "sts:AssumeRoleWithWebIdentity"
          Condition = {
            StringEquals = { "${local.oidc_info[k].host}:aud" = r.audiences }
            StringLike   = { "${local.oidc_info[k].host}:sub" = r.subjects }
          }
        }] : [],
        length(r.trusted_services) > 0 ? [{
          Effect    = "Allow"
          Principal = { Service = r.trusted_services }
          Action    = "sts:AssumeRole"
        }] : [],
      )
    })
  }

  roles_all = merge(
    {
      for k, r in var.var.roles : k => {
        description          = r.description
        path                 = r.path
        max_session_duration = r.max_session_duration
        trust                = local.cicd_trust[k]
        policy_keys          = r.policy_keys
        policy_arns          = r.policy_arns
        instance_profile     = false
        tags                 = r.tags
        boundary = (
          r.permissions_boundary_arn != null ? r.permissions_boundary_arn :
          r.permissions_boundary_key != null ? local.policy_arns["boundary/${r.permissions_boundary_key}"] :
          var.default_permissions_boundary_arn
        )
      }
    },
    {
      for k, r in var.cicd_roles : k => {
        description          = r.description
        path                 = r.path
        max_session_duration = r.max_session_duration
        trust                = local.cicd_trust[k]
        policy_keys          = r.policy_keys
        policy_arns          = r.policy_arns
        instance_profile     = false
        tags                 = r.tags
        boundary = (
          r.permissions_boundary_arn != null ? r.permissions_boundary_arn :
          r.permissions_boundary_key != null ? local.policy_arns["boundary/${r.permissions_boundary_key}"] :
          var.default_permissions_boundary_arn
        )
      }
    },
  )

  role_attach_by_key  = merge([for k, r in local.roles_all : { for pk in r.policy_keys : "${k}|${p}" => { principal = k, policy_key = pk } }]...)
  role_attach_by_arn  = merge([for k, r in local.roles_all : { for a in r.policy_arns : "${k}|${a}" => { principal = k, arn = a } }]...)
  group_attach_by_key = merge([for k, g in var.groups : { for pk in g.policy_keys : "${k}|${pk}" => { principal = k, policy_key = pk } }]...)
  group_attach_by_arn = merge([for k, g in var.groups : { for a in g.policy_arns : "${k}|${a}" => { principal = k, arn = a } }]...)
  user_attach_by_key  = merge([for k, u in var.users : { for pk in u.policy_keys : "${k}|${pk}" => { principal = k, policy_key = pk } }]...)
  user_attach_by_arn  = merge([for k, u in var.users : { for a in u.policy_arns : "${k}|${a}" => { principal = k, arn = a } }]...)
}

check "unique_role_keys" {
  assert {
    condition     = length(setintersection(keys(var.roles), keys(var.cicd_roles))) == 0
    error_message = "Keys in 'roles' and 'cicd_roles' must be unique (they share one aws_iam_role resource)."
  }
}

# Policies & permission boundaries
data "aws_iam_policy_document" "this" {
  for_each = { for k, v in local.policy_defs : k => v if v.policy_json == null }

  dynamic "statement" {
    for_each = each.value.statements
    content {
      sid           = statement.value.sid
      effect        = statement.value.effect
      actions       = statement.value.actions
      not_actions   = statement.value.not_actions
      resources     = statement.value.resources
      not_resources = statement.value.not_resources

      dynamic "condition" {
        for_each = statement.value.conditions
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_policy" "this" {
  for_each = local.policy_defs

  name        = "${var.name_prefix}${split("/", each.key)[1]}"
  path        = each.value.path
  description = each.value.description
  policy      = each.value.policy_json != null ? each.value.policy_json : data.aws_iam_policy_document.this[each.key].json
  tags        = var.tags
}


# Groups
resource "aws_iam_group" "this" {
  for_each = var.groups

  name = "${var.name_prefix}${each.key}"
  path = each.value.path
}


resource "aws_iam_group_policy_attachment" "by_key" {
  for_each = local.group_attach_by_key

  group      = aws_iam_group.this[each.value.principal].name
  policy_arn = local.policy_arns["policy/${each.value.policy_key}"]
}


resource "aws_iam_group_policy_attachment" "by_arn" {
  for_each = local.group_attach_by_arn

  group      = aws_iam_group.this[each.value.principal].name
  policy_arn = each.value.arn
}


# Users
resource "aws_iam_user" "this" {
  for_each = var.users

  name          = each.key
  path          = each.value.path
  force_destroy = each.value.force_destroy
  permissions_boundary = (
    each.value.permission_boundary_arn != null ? each.value.permissions_boundary_arn :
    each.value.permission_boundary_key != null ? local.policy_arns["boundary/${each.value.permissions_boundary_key}"] :
    var.default_permissions_boundary_arn
  )
  tags = merge(var.tags, each.value.tags)
}

resource "aws_iam_user_group_membership" "this" {
  for_each = { for k, u in var.users : k => u if length(u.groups) > 0 }

  user   = aws_iam_user.this[each.value.principal].name
  groups = [for g in each.value.groups : aws_iam_group.this[g].name]
}


resource "aws_iam_user_policy_attachment" "by_key" {
  for_each = local.user_attach_by_key

  user       = aws_iam_user.this[each.value.principal].name
  policy_arn = local.policy_arns["policy/${each.value.policy_key}"]
}


resource "aws_iam_user_policy_attachment" "by_arn" {
  for_each = local.user_attach_by_arn

  user       = aws_iam_user.this[each.value.principal].name
  policy_arn = each.value.arn
}


# OIDC providers (Github Actions, GitLab, etc.)
resource "aws_iam_openid_connect_provider" "this" {
  for_each = var.oidc_providers

  url             = each.value.url
  client_id_list  = each.value.client_id_list
  thumbprint_list = length(each.value.thumbprint_list) > 0 ? each.value.thumbprint_list : null
  tags            = var.tags
}


# Roles (service, cross-account, CI/CD)
resource "aws_iam_role" "this" {
  for_each = local.roles_all

  name                  = "${var.name_prefix}${each.key}"
  path                  = each.value.path
  description           = each.value.description
  assume_role_policy    = each.value.trust
  max_session_duration  = each.value.max_session_duration
  permissions_boundary  = each.value.boundary
  force_detach_policies = true
  tags                  = merge(var.tags, each.value.tags)
}


resource "aws_iam_role_policy_attachment" "by_key" {
  for_each = local.role_attach_by_key

  role       = aws_iam_role.this[each.value.principal].name
  policy_arn = each.value.arn
}

resource "aws_iam_role_policy_attachment" "by_arn" {
  for_each = local.role_attach_by_arn

  role       = aws_iam_role.this[each.value.principal].name
  policy_arn = each.value.arn
}


resource "aws_iam_instance_profile" "this" {
  for_each = { for k, r in local.local.roles_all : k => r if r.instance_profile }

  name = aws_iam_role.this[each.key].name
  role = aws_iam_role.this[each.key].name
  path = each.value.path
  tags = var.tags
}
