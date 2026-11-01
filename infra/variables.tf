variable "aws_region" {
  description = "Region for the AWS provider."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix for all names created here (roles, policies)."
  type        = string
  default     = "cob-"
}

variable "github_org" {
  description = "GitHub organisation or user that owns the live repo."
  type        = string
}

variable "github_repo" {
  description = "Repository allowed to assume the pipeline role (e.g. cob-terraform-live)."
  type        = string
}

variable "allowed_branch" {
  description = "Only runs from this branch may assume the role."
  type        = string
  default     = "main"
}

variable "allowed_regions" {
  description = "Regions that principals created by the pipeline may use (global services are exempt)."
  type        = list(string)
  default     = ["eu-west-2"]
}

variable "create_oidc_provider" {
  description = "Set false if the GitHub OIDC provider already exists in this account (only one per URL is allowed)."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = { Project = "COB", ManagedBy = "terraform", Stack = "bootstrap" }
}

variable "github_sub_prefix" {
  description = "Subject prefix GitHub puts in OIDC tokens for the pipeline repo (from the repo's OIDC customization API: sub_claim_prefix)."
  type        = string
}