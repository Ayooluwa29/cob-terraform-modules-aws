terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.81.0"
    }
  }

  backend "s3" {
    bucket       = "cob-bstrap-tfstate"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  github_oidc   = "token.actions.githubusercontent.com"
  pipeline_key  = "github-terraform"
  pipeline_name = "${var.name_prefix}${local.pipeline_key}"

  # Built from strings (not module outputs) so the pipeline policy can reference
  # resources the module creates without a dependency cycle.
  boundary_arn      = "arn:aws:iam::${local.account_id}:policy/boundaries/${var.name_prefix}standard"
  pipeline_role_arn = "arn:aws:iam::${local.account_id}:role/cicd/${local.pipeline_name}"
  oidc_provider_arn = "arn:aws:iam::${local.account_id}:oidc-provider/${local.github_oidc}"
}

module "iam" {
  source = "git::https://github.com/Ayooluwa29/cob-terraform-modules-aws.git//modules/iam?ref=main"

  name_prefix = var.name_prefix
  tags        = var.tags

  # ---- 1. Trust anchor ----
  oidc_providers = var.create_oidc_provider ? {
    github = {
      url            = "https://${local.github_oidc}"
      client_id_list = ["sts.amazonaws.com"]
    }
  } : {}

  # ---- 2. Boundary that every principal the pipeline creates must carry ----
  permission_boundaries = {
    standard = {
      statements = [
        {
          sid       = "AllowAll"
          actions   = ["*"]
          resources = ["*"]
        },
        {
          sid    = "DenyIdentityAdministration"
          effect = "Deny"
          actions = [
            "iam:Create*", "iam:Attach*", "iam:Put*", "iam:Update*",
            "iam:Delete*", "iam:Add*", "iam:Set*",
            "organizations:*", "account:*",
          ]
          resources = ["*"]
        },
        {
          sid         = "DenyOutsideApprovedRegions"
          effect      = "Deny"
          not_actions = ["iam:*", "sts:*", "organizations:*", "route53:*", "cloudfront:*", "support:*"]
          resources   = ["*"]
          conditions = [{
            test     = "StringNotEquals"
            variable = "aws:RequestedRegion"
            values   = var.allowed_regions
          }]
        },
      ]
    }
  }

  # ---- 3. What the pipeline may do ----
  policies = {
    pipeline = {
      description = "Permissions for the Terraform pipeline role"
      statements = [
        {
          sid = "ManageInfrastructure"
          # Starting point - trim to the services your modules actually use.
          actions = [
            "ec2:*", "s3:*", "rds:*", "ecs:*", "ecr:*", "lambda:*", "logs:*",
            "redshift:*", "glue:*", "athena:*", "elasticloadbalancing:*",
            "kms:*", "secretsmanager:*", "ssm:*", "cloudwatch:*", "events:*",
          ]
          resources = ["*"]
        },
        {
          sid = "ManageIamWithinBoundary"
          # Creating a principal is only allowed if it carries the boundary.
          actions = [
            "iam:CreateRole", "iam:CreateUser",
            "iam:PutRolePermissionsBoundary", "iam:PutUserPermissionsBoundary",
          ]
          resources = ["*"]
          conditions = [{
            test     = "StringEquals"
            variable = "iam:PermissionsBoundary"
            values   = [local.boundary_arn]
          }]
        },
        {
          sid = "ManageIamOther"
          actions = [
            "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion",
            "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
            "iam:AttachUserPolicy", "iam:DetachUserPolicy",
            "iam:AttachGroupPolicy", "iam:DetachGroupPolicy",
            "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:DeleteRole", "iam:DeleteUser",
            "iam:CreateGroup", "iam:DeleteGroup", "iam:AddUserToGroup", "iam:RemoveUserFromGroup",
            "iam:TagRole", "iam:UntagRole", "iam:TagUser", "iam:UntagUser", "iam:TagPolicy", "iam:UntagPolicy",
            "iam:PassRole", "iam:Get*", "iam:List*",
          ]
          resources = ["*"]
        },
        {
          sid       = "NeverStripABoundary"
          effect    = "Deny"
          actions   = ["iam:DeleteRolePermissionsBoundary", "iam:DeleteUserPermissionsBoundary"]
          resources = ["*"]
        },
        {
          sid    = "ProtectBootstrapResources"
          effect = "Deny"
          actions = [
            "iam:Create*", "iam:Put*", "iam:Update*", "iam:Delete*", "iam:Attach*", "iam:Detach*",
            "iam:Add*", "iam:Remove*", "iam:Set*", "iam:Tag*", "iam:Untag*",
          ]
          resources = [local.pipeline_role_arn, local.boundary_arn, local.oidc_provider_arn]
        },
      ]
    }

    plan-state = {
      description = "State access for read-only plans"
      statements = [
        {
          sid       = "ListStateBucket"
          actions   = ["s3:ListBucket"]
          resources = ["arn:aws:s3:::cob-bstrap-tfstate"]
        },
        {
          sid       = "ReadWriteStateAndLocks"
          actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          resources = ["arn:aws:s3:::cob-bstrap-tfstate/envs/*"]
        },
      ]
    }
  }

  # ---- 4. The CI/CD role itself ----
  cicd_roles = {
    # Apply role: assumed on pushes to main (used by cd.yml)
    (local.pipeline_key) = {
      description       = "Assumed by GitHub Actions in ${var.github_org}/${var.github_repo} to apply Terraform"
      oidc_provider_key = var.create_oidc_provider ? "github" : null
      oidc_provider_arn = var.create_oidc_provider ? null : local.oidc_provider_arn
      subjects          = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.allowed_branch}"]
      policy_keys       = ["pipeline"]
      subjects = ["${var.github_sub_prefix}:ref:refs/heads/${var.allowed_branch}"]
      # No boundary on the pipeline role itself: the guardrails live in its policy
      # (boundary-conditioned IAM writes + explicit denies) and in the boundary it forces on everything it creates.
    }

    # Plan role: assumed on pull requests, read-only (used by ci.yml)
    github-terraform-plan = {
      description       = "Read-only plans for pull requests in ${var.github_org}/${var.github_repo}"
      oidc_provider_key = var.create_oidc_provider ? "github" : null
      oidc_provider_arn = var.create_oidc_provider ? null : local.oidc_provider_arn
      subjects          = ["repo:${var.github_org}/${var.github_repo}:pull_request"]
      policy_keys       = ["plan-state"]
      policy_arns       = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      subjects = ["${var.github_sub_prefix}:pull_request"]
    }
  }
}
