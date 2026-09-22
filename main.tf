terraform {
  required_version = ">= 1.3.0"
  required_providers {
    wiz = {
      source  = "tf.app.wiz.io/wizsec/wiz"
      version = "~> 1.0"
    }
  }
}

provider "wiz" {
  client_id     = var.wiz_client_id
  secret        = var.wiz_client_secret
}

# ------------------------------------------------------------------------------
# Variables
# ------------------------------------------------------------------------------

variable "wiz_client_id" {
  description = "Wiz OAuth client ID"
  type        = string
  sensitive   = true
}

variable "wiz_client_secret" {
  description = "Wiz OAuth client secret"
  type        = string
  sensitive   = true
}

variable "json_import_file" {
  description = "Path to the JSON import file relative to the module"
  type        = string
  default     = "wiz_import.json"
}

variable "master_folder_name" {
  description = "Name of the root master folder"
  type        = string
  default     = "Code Orgs"
}

variable "managed_by_tag" {
  description = "Value for the managed_by tag applied to all resources"
  type        = string
  default     = "json-import-script"
}

# ------------------------------------------------------------------------------
# Locals
# ------------------------------------------------------------------------------

locals {
  json_data = jsondecode(file("${path.module}/${var.json_import_file}"))

  folders = {
    for f in lookup(local.json_data, "folders", []) : f.name => f
  }

  nested_projects = flatten([
    for f_name, f_data in local.folders : [
      for p in lookup(f_data, "projects", []) : {
        key          = "${f_name}/${p.name}"
        folder_name  = f_name
        project_name = p.name
        repositories = distinct([
          for r in lookup(p, "repositories", []) : r.name
          if lookup(r, "name", "") != ""
        ])
        users = lookup(p, "users", [])
      }
    ]
  ])

  standalone_projects = [
    for p in lookup(local.json_data, "standalone_projects", []) : {
      key          = "standalone/${p.name}"
      folder_name  = null
      project_name = p.name
      repositories = distinct([
        for r in lookup(p, "repositories", []) : r.name
        if lookup(r, "name", "") != ""
      ])
      users = lookup(p, "users", [])
    }
  ]

  all_projects = merge(
    { for p in local.nested_projects : p.key => p },
    { for p in local.standalone_projects : p.key => p }
  )

  # All unique repo names across all projects
  all_repo_names = distinct(flatten([
    for p in local.all_projects : p.repositories
  ]))

  # For each repo name, extract short name and whether it has an owner prefix
  repo_search_map = {
    for repo_name in local.all_repo_names : repo_name => {
      has_owner  = strcontains(repo_name, "/")
      short_name = split("/", repo_name)[length(split("/", repo_name)) - 1]
    }
  }

  # Resolve repo asset IDs: exact full-path match first,
  # short-name fallback only when no owner prefix in input
  resolved_repo_ids = {
    for repo_name, meta in local.repo_search_map :
    repo_name => try(
      [
        for r in data.wiz_repositories.lookup[repo_name].repositories :
        r.id
        if lower(r.name) == lower(repo_name)
      ][0],
      meta.has_owner ? null : try(
        [
          for r in data.wiz_repositories.lookup[repo_name].repositories :
          r.id
          if lower(split("/", r.name)[length(split("/", r.name)) - 1]) == lower(meta.short_name)
        ][0],
        null
      )
    )
  }

  # All unique user emails across all projects
  all_user_emails = distinct(flatten([
    for p in local.all_projects : [
      for u in lookup(p, "users", []) : u.email
    ]
  ]))

  # Per-project admin emails (-> project_owners)
  project_admin_emails = {
    for k, p in local.all_projects : k => [
      for u in lookup(p, "users", []) : u.email
      if lookup(u, "role", "") == "admin"
    ]
  }

  # Per-project user emails (-> security_champions)
  project_user_emails = {
    for k, p in local.all_projects : k => [
      for u in lookup(p, "users", []) : u.email
      if lookup(u, "role", "") == "user"
    ]
  }

  # Build email -> Wiz user ID map, null if not found. This is the raw
  # lookup result before filtering out IDs the wiz_project resource can't
  # accept as project_owners/security_champions (see below).
  raw_resolved_user_ids = {
    for email in local.all_user_emails :
    email => try(
      [
        for u in data.wiz_users.lookup[email].wiz_users :
        u.id
        if lower(u.email) == lower(email)
      ][0],
      null
    )
  }

  # NOTE: an earlier version of this file filtered resolved IDs by UUID
  # shape, based on a report that a "xx-sso_*"-formatted ID got rejected
  # by wiz_project. That turned out to be a false generalization: real
  # production testing confirmed Wiz's own UI assigns project owners using
  # exactly this non-UUID, idp-prefixed ID shape (e.g.
  # "comp-okta_<email>") for SAML/SSO-authenticated users, so ID *shape*
  # is not a reliable signal of validity either way. The only thing we
  # actually know is whether the wiz_users lookup found a match at all.
  resolved_user_ids = local.raw_resolved_user_ids
}

# ------------------------------------------------------------------------------
# Data Sources - Repositories
# ------------------------------------------------------------------------------

data "wiz_repositories" "lookup" {
  for_each = local.repo_search_map
  search   = [each.value.short_name]
}

# ------------------------------------------------------------------------------
# Data Sources - Users
# ------------------------------------------------------------------------------

data "wiz_users" "lookup" {
  for_each = toset(local.all_user_emails)
  search   = each.value
}

# ------------------------------------------------------------------------------
# Master Folder
# ------------------------------------------------------------------------------

resource "wiz_project" "master_folder" {
  name        = var.master_folder_name
  slug        = uuidv5("dns", "wiz-tf-master-folder-${var.master_folder_name}")
  description = "Configured via Terraform automation"
  is_folder   = true

  tags {
    key   = "managed_by"
    value = var.managed_by_tag
  }

  # Uncomment if you want to guarantee `terraform destroy` can never remove
  # the root of your whole hierarchy, even by accident:
  # lifecycle {
  #   prevent_destroy = true
  # }
}

# ------------------------------------------------------------------------------
# Category Sub-Folders
# ------------------------------------------------------------------------------

resource "wiz_project" "category_folders" {
  for_each = local.folders

  name              = each.key
  slug              = uuidv5("dns", "wiz-tf-category-folder-${each.key}")
  description       = "Category folder created via Terraform automation"
  is_folder         = true
  parent_project_id = wiz_project.master_folder.id

  tags {
    key   = "managed_by"
    value = var.managed_by_tag
  }
}

# ------------------------------------------------------------------------------
# Leaf Projects
# ------------------------------------------------------------------------------

resource "wiz_project" "projects" {
  for_each = local.all_projects

  name        = each.value.project_name
  slug        = uuidv5("dns", "wiz-tf-project-${each.key}")
  description = "Configured via Terraform automation"
  is_folder   = false

  parent_project_id = (
    each.value.folder_name != null
    ? wiz_project.category_folders[each.value.folder_name].id
    : wiz_project.master_folder.id
  )

  tags {
    key   = "managed_by"
    value = var.managed_by_tag
  }

  risk_profile {
    business_impact = "MBI"
  }

  dynamic "repository_links" {
    for_each = [
      for repo_name in each.value.repositories :
      local.resolved_repo_ids[repo_name]
      if lookup(local.resolved_repo_ids, repo_name, null) != null
    ]
    content {
      repository = repository_links.value
    }
  }

  # Admins -> project_owners
  project_owners = [
    for email in local.project_admin_emails[each.key] :
    local.resolved_user_ids[email]
    if lookup(local.resolved_user_ids, email, null) != null
  ]

  # Users -> security_champions
  security_champions = [
    for email in local.project_user_emails[each.key] :
    local.resolved_user_ids[email]
    if lookup(local.resolved_user_ids, email, null) != null
  ]
}

# ------------------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------------------

output "master_folder_id" {
  description = "ID of the root master folder"
  value       = wiz_project.master_folder.id
}

output "category_folder_ids" {
  description = "IDs of category sub-folders"
  value       = { for k, v in wiz_project.category_folders : k => v.id }
}

output "project_ids" {
  description = "IDs of all projects"
  value       = { for k, v in wiz_project.projects : k => v.id }
}

output "unresolved_repos" {
  description = "Repo names that could not be matched to a Wiz asset ID"
  value = [
    for repo_name, asset_id in local.resolved_repo_ids :
    repo_name
    if asset_id == null
  ]
}

output "unresolved_users" {
  description = "User emails that could not be matched to a Wiz user ID at all"
  value = [
    for email, id in local.raw_resolved_user_ids :
    email
    if id == null
  ]
}

output "resolved_user_ids" {
  description = "Email -> Wiz user ID map used for project_owners/security_champions (null only for emails the wiz_users lookup couldn't match at all)"
  value       = local.resolved_user_ids
}

output "raw_resolved_user_ids" {
  description = "Every user email in the input alongside the raw ID Wiz returned for it (null if unresolved) — for debugging what Wiz's user lookup actually returns. Currently identical to resolved_user_ids; kept as a separate output in case ID filtering is reintroduced later"
  value       = local.raw_resolved_user_ids
}
