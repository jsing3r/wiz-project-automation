# Wiz Project Structure Automation - Terraform

## Overview

This Terraform module automates the creation and management of Wiz project hierarchies from a JSON configuration file. It handles folder creation, project creation, repository linking, and user assignment in a single `terraform apply`.

## Features

- Creates a root master folder (`Code Orgs` by default)
- Creates category sub-folders (e.g. `App1`, `App2`, `App3`)
- Creates leaf projects under their correct parent folders
- Links VCS repositories to projects using exact path matching
- Assigns users to projects based on role (`admin` → project owner, `user` → security champion)
- Skips users that haven't logged into Wiz via SAML yet - no errors, just skipped
- Outputs unresolved repositories and users after each apply

---

## Prerequisites

- Terraform >= 1.3.0
- Network access to `tf.app.wiz.io` (Wiz private provider registry)
- A Wiz service account with the following permissions:
  - `create:projects`
  - `update:projects`
  - `read:resources`
  - `read:users`

---

## Directory Structure

```
your-directory/
├── main.tf
├── terraform.tfvars.example
├── wizcode_project_structure_example.json
├── README.md
└── .gitignore
```


---

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/jsing3r/wiz-project-automation.git
cd wiz-project-automation
```

### 2. Configure credentials

Copy the example vars file and fill in your Wiz service account credentials:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
wiz_client_id      = "your-client-id"
wiz_client_secret  = "your-client-secret"
json_import_file   = "wizcode_project_structure.json"
master_folder_name = "Code Orgs"
```

> **Never commit `terraform.tfvars` to source control.** It contains sensitive credentials and is excluded via `.gitignore`.

### 3. Create your project structure file

Copy the example file as a starting point:

```bash
cp wizcode_project_structure_example.json wizcode_project_structure.json
```

Edit `wizcode_project_structure.json` to reflect your actual project hierarchy. See the [JSON Input Format](#json-input-format) section below for full details.

Validate the JSON before running Terraform:

```bash
python3 -c "import json; json.load(open('wizcode_project_structure.json')); print('Valid JSON')"
```

### 4. Initialize Terraform

```bash
terraform init
```

### 5. Review the plan

```bash
terraform plan
```

Check the output for:
- Folders and projects that will be created
- `unresolved_repos` — repositories that could not be matched in Wiz
- `unresolved_users` — users that haven't logged into Wiz via SAML yet

### 6. Apply

```bash
terraform apply
```

---

## JSON Input Format

The input file defines folders, projects, repositories, and users in a hierarchical structure. Use `wizcode_project_structure_example.json` as a starting point.

```json
{
  "folders": [
    {
      "name": "Folder A",
      "projects": [
        {
          "name": "A - First Project",
          "repositories": [
            { "name": "owner/repo1" },
            { "name": "repo-short-name" }
          ],
          "users": [
            { "email": "owner@company.com", "role": "admin" },
            { "email": "champion@company.com", "role": "user" }
          ]
        }
      ]
    }
  ],
  "standalone_projects": [
    {
      "name": "My Standalone Project",
      "repositories": [
        { "name": "owner/repo" }
      ],
      "users": [
        { "email": "owner@company.com", "role": "admin" }
      ]
    }
  ]
}
```

### Field Reference

| Field | Required | Description |
|---|---|---|
| `folders[].name` | Yes | Category folder name. Must be unique. |
| `folders[].projects[].name` | Yes | Project name. Must be unique across the entire Wiz tenant. |
| `folders[].projects[].repositories[].name` | No | Repository name. Can be `owner/repo` or short name. |
| `folders[].projects[].users[].email` | No | User email address. |
| `folders[].projects[].users[].role` | Yes | Either `admin` or `user`. Every user entry must have a role. |
| `standalone_projects` | No | Projects created directly under the master folder. |

### Repository Name Matching

Repository names are matched using the following logic:

- `owner/repo` — exact full path match only. Will not match a repo with a different owner.
- `repo` (no owner) — short name match. Matches the first repo whose name ends with that value.

Repositories that cannot be matched are skipped and reported in the `unresolved_repos` output.

### Role Mapping

| JSON role | Wiz assignment |
|---|---|
| `admin` | Project Owner |
| `user` | Security Champion |

---

## Variables

| Variable | Default | Description |
|---|---|---|
| `wiz_client_id` | — | Wiz OAuth client ID (required) |
| `wiz_client_secret` | — | Wiz OAuth client secret (required) |
| `json_import_file` | `wiz_import.json` | Path to the JSON input file |
| `master_folder_name` | `Code Orgs` | Name of the root master folder |
| `managed_by_tag` | `json-import-script` | Tag value applied to all created resources |

---

## Outputs

| Output | Description |
|---|---|
| `master_folder_id` | Wiz ID of the root master folder |
| `category_folder_ids` | Map of category folder names to Wiz IDs |
| `project_ids` | Map of project keys to Wiz IDs |
| `unresolved_repos` | Repository names that could not be matched to a Wiz asset ID |
| `unresolved_users` | User emails that could not be matched to a Wiz user ID |

---

## Day-2 Operations

### Adding new projects or folders

Add entries to `wizcode_project_structure.json` and run:

```bash
terraform apply
```

Terraform will only create new resources and leave existing ones untouched.

### Adding users after SAML login

As users log into Wiz for the first time via SAML, run:

```bash
terraform apply
```

Newly provisioned users will automatically be assigned to their projects.

### Updating repository links

Update the `repositories` list for a project in the JSON and run `terraform apply`. Terraform will reconcile the repository links.

### Removing a project

Remove the entry from the JSON and run `terraform apply`. By default the Wiz provider **archives** projects on destroy rather than hard-deleting them.

---

## Known Limitations

### Project name uniqueness

Wiz enforces global uniqueness on project names across the entire tenant. If the same project name appears in multiple folders, Terraform will fail on the second creation. Use a naming convention that includes the folder prefix to avoid collisions, e.g. `STS - Project Name` rather than just `Project Name`.

### Repository linking

The Wiz Terraform provider does not expose a direct data source for resolving repository asset IDs by exact path. This module uses the `wiz_repositories` data source with a short-name search and applies exact matching logic in locals to resolve the correct asset ID.

### SAML users

Users are looked up via the `wiz_users` data source. Users who have not yet logged into Wiz via SAML will not be found and will be silently skipped. Re-run `terraform apply` after users have logged in to assign them to their projects.

---

## Troubleshooting

### `Project names must be unique` error

Two projects in your JSON have the same name. Rename one to make it unique across the tenant, then re-run `terraform apply`. If projects were partially created, run `terraform destroy` first to clean up.

### `bad credentials` error

Your client ID or secret is invalid or has been rotated. Generate new credentials in Wiz under **Settings → Service Accounts** and update `terraform.tfvars`.

### Users not being assigned to projects

1. Confirm the user has logged into Wiz at least once via SAML
2. Confirm every user entry in the JSON has a `role` field
3. Validate the JSON file:
```bash
   python3 -c "import json; json.load(open('wizcode_project_structure.json')); print('Valid JSON')"
```
4. Run `terraform console` and check `local.resolved_user_ids` to verify which users resolved successfully
5. Re-run `terraform apply` to pick up newly provisioned users

### Repositories showing in `unresolved_repos`

1. Confirm the repository is connected to Wiz via a VCS connector
2. Check the name in the JSON matches exactly what Wiz has indexed under **Settings → Connectors**
3. For `owner/repo` format, confirm the owner prefix matches exactly

### Invalid JSON error during `terraform plan`

Validate the JSON file:

```bash
python3 -c "import json; json.load(open('wizcode_project_structure.json')); print('Valid JSON')"
```

Common issues:
- Missing comma between `folders` and `standalone_projects`
- Missing `}` to close a folder or project object
- Missing `role` field on a user entry
