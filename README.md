# Wiz Project Structure Automation - Terraform

## Overview

This Terraform module automates the creation and management of Wiz project hierarchies from a JSON configuration file. It handles folder creation, project creation, repository linking, and user assignment in a single `terraform apply`.

## Features

- Creates a root master folder (`Code Orgs` by default)
- Creates category sub-folders (e.g. `App1`, `App2`, `App3`)
- Creates leaf projects under their correct parent folders
- Links VCS repositories to projects using exact path matching
- Assigns users to projects based on role (`admin` → project owner, `user` → security champion)
- Skips users that haven't logged into Wiz yet - no errors, just skipped
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
├── tests/
│   ├── user_id_resolution.tftest.hcl
│   └── fixtures/
│       └── test_import.json
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
- `unresolved_users` — users that haven't logged into Wiz yet, or that Wiz doesn't recognize at all

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
| `unresolved_users` | User emails that could not be matched to a Wiz user ID at all |
| `resolved_user_ids` | Email → Wiz user ID used for `project_owners`/`security_champions` (`null` only if the email couldn't be matched to a Wiz user at all) |
| `raw_resolved_user_ids` | Same as `resolved_user_ids` — kept as a separate output for debugging in case ID filtering is reintroduced later |

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

Wiz enforces global uniqueness on project *names* across the entire tenant. If a project with a given name already exists in Wiz — created manually, by another tool, or from before this module started managing it — `terraform apply` will fail with `Project names must be unique`, and everything depending on that project (child folders, leaf projects) will fail with it.

**This module intentionally does not try to auto-detect and silently adopt pre-existing projects by name.** An earlier version of this file did, using a runtime `wiz_projects` lookup to fall back to an existing project's ID instead of creating a duplicate — but that pattern is fundamentally incompatible with `terraform destroy`/full lifecycle management: a project adopted by reference is never actually tracked in state, so `apply` silently can't update its repo links, owners, or tags, and `destroy` can't remove it either. Worse, if such logic later gets combined with `terraform import`, the runtime lookup keeps re-detecting the now-imported project as "already existing" and excludes it from Terraform's managed set again, causing it to look orphaned and get destroyed on the next `apply` — a real bug this project shipped with briefly.

The correct, supported way to bring a pre-existing project under management is `terraform import`:

```bash
terraform import wiz_project.master_folder <existing-project-id>
terraform import 'wiz_project.category_folders["Folder Name"]' <existing-project-id>
terraform import 'wiz_project.projects["Folder Name/Project Name"]' <existing-project-id>
```

Find the ID from the Wiz console (it's in the project's URL) or via `terraform console` and a one-off `wiz_projects` data source query. After importing, run `terraform plan` and review the diff carefully before applying — a project that predates this config likely won't match its `slug`, `description`, or `tags` yet, and `apply` will rewrite those on the real, live project.

Separately, Wiz also enforces uniqueness on the project **slug**, which by default it derives from the name — this can cause `slug already exists` conflicts independent of the name-collision case above. `main.tf` sets `slug` explicitly on every `wiz_project` resource, computed with `uuidv5()` from each resource's unique Terraform key. This is deterministic (the same project always gets the same slug across repeated `apply` runs, so it won't get needlessly replaced) and effectively collision-proof against anything already in the tenant.

If you want to guarantee `terraform destroy` can never remove your root folder even by accident, add a `lifecycle { prevent_destroy = true }` block to `wiz_project.master_folder` (commented out in `main.tf` by default).

### Repository linking

The Wiz Terraform provider does not expose a direct data source for resolving repository asset IDs by exact path. This module uses the `wiz_repositories` data source with a short-name search and applies exact matching logic in locals to resolve the correct asset ID.

### SAML/SSO users

Users are looked up via the `wiz_users` data source. If an email doesn't match any Wiz user, it's skipped for that project (reported in `unresolved_users`) rather than failing the apply — most commonly because the user hasn't logged into Wiz yet. Re-run `terraform apply` after they've logged in.

**A note on ID shape:** Wiz's internal user IDs are not always UUIDs. SSO/SAML-authenticated users can have IDs like `comp-okta_<email>` — this is confirmed as the exact ID format Wiz's own UI assigns for project ownership on such accounts, not an error condition. An earlier version of this module filtered these out under the mistaken assumption that only UUID-shaped IDs were valid; that filtering has been removed. `resolved_user_ids` now uses any ID the lookup finds, regardless of shape.

If you ever hit an actual rejection from Wiz for a specific resolved ID (an apply-time error, not just "not found"), that's a real, new case worth handling explicitly — it is not something to solve by guessing at ID shape again. Check that project's `data.wiz_users.lookup[email]` entry via `terraform console` to see exactly what was resolved, and compare it against what Wiz's UI stores for that same user (see [Testing](#testing) for how to check that).

---

## Testing

`tests/user_id_resolution.tftest.hcl` unit-tests the user ID resolution logic (`resolved_user_ids` / `unresolved_users` above) using Terraform's native test framework, `terraform test` (Terraform >= 1.7).

It mocks the `wiz` provider entirely (`mock_provider "wiz" {}`), so it makes no real API calls and needs no real credentials — this is what lets it assert on specific ID shapes (like a non-UUID SSO ID) without needing a matching account in your actual tenant.

Run it with:

```bash
terraform test
```

### How it works

The test points `json_import_file` at a small fixture, `tests/fixtures/test_import.json`, containing one project with three users:

| Email | Role | What it's testing |
|---|---|---|
| `good@example.com` | admin | A normal, resolvable user with a UUID-shaped ID |
| `sso@example.com` | admin | A user that resolves to a non-UUID, idp-prefixed ID — the same shape Wiz's own UI uses for SSO/SAML-authenticated project owners (`comp-okta_<email>`, confirmed against a real tenant, not a guess) |
| `missing@example.com` | user | A user that doesn't resolve at all |

`override_data` blocks fake what `data.wiz_users.lookup` returns for each of those three emails.

The test then asserts, end to end:
- both `good@example.com` and `sso@example.com` survive into `resolved_user_ids` and into the leaf project's `project_owners`, regardless of the very different shape of their IDs
- only the fully-unresolved `missing@example.com` ends up `null` in `resolved_user_ids` and appears in `unresolved_users`

This test exists specifically to guard against reintroducing ID-shape filtering by mistake — a prior version of this module did, and it silently dropped valid SSO users from `project_owners`.

### Adding more cases

To test another scenario (a user with multiple `wiz_users` matches, a different idp prefix, etc.), add another entry to `tests/fixtures/test_import.json`, add a matching `override_data` block in `tests/user_id_resolution.tftest.hcl`, and add assertions for the expected outcome.

---

## Troubleshooting

### `Project names must be unique` error

Two possibilities:
1. **The name genuinely matches a pre-existing Wiz project** (created manually, by another tool, or before this module managed it). Bring it under management with `terraform import` — see [Project name uniqueness](#project-name-uniqueness) for the exact commands — rather than trying to work around it in the JSON.
2. **It's a genuine duplicate** — the same name used for two *different* intended projects in your JSON. Rename one to make it unique (e.g. prefix with the folder name), then re-run `terraform apply`. If projects were partially created, run `terraform destroy` first to clean up.

### `bad credentials` error

Your client ID or secret is invalid or has been rotated. Generate new credentials in Wiz under **Settings → Service Accounts** and update `terraform.tfvars`.

### Users not being assigned to projects

1. Confirm the user has logged into Wiz at least once via SAML
2. Confirm every user entry in the JSON has a `role` field
3. Validate the JSON file:
```bash
   python3 -c "import json; json.load(open('wizcode_project_structure.json')); print('Valid JSON')"
```
4. Run `terraform console` and check `local.resolved_user_ids` / `data.wiz_users.lookup[email]` to see exactly what Wiz resolved that email to
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
