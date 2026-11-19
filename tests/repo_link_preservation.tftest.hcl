# Run with: terraform test
#
# Mocks the wiz provider entirely - no real API calls or credentials.
#
# Covers preserve_unlisted_repo_links:
#   - repo-listed : in the JSON and already linked in Wiz  -> always kept
#   - repo-manual : linked in Wiz but NOT in the JSON       -> kept only when
#                   preserve_unlisted_repo_links = true
#   - repo-other  : linked to a different project whose name fuzzy-matches
#                   the search -> must never leak into this project
#
# These override_data blocks also check the assumed shape of the
# wiz_projects data source (projects[].name,
# projects[].repository_links[].repository). If the real provider schema
# differs, this test fails, which tells you main.tf needs adjusting.

mock_provider "wiz" {}

variables {
  wiz_client_id     = "mock-client-id"
  wiz_client_secret = "mock-client-secret"
  json_import_file  = "tests/fixtures/test_repo_links.json"
}

override_data {
  target = data.wiz_repositories.lookup["owner/listed"]
  values = {
    repositories = [
      { id = "repo-listed", name = "owner/listed" }
    ]
  }
}

override_data {
  target = data.wiz_projects.existing["TestFolder/repo-project"]
  values = {
    projects = [
      {
        name = "repo-project"
        repository_links = [
          { repository = "repo-listed" },
          { repository = "repo-manual" }
        ]
      },
      {
        name = "repo-project-other"
        repository_links = [
          { repository = "repo-other" }
        ]
      }
    ]
  }
}

run "preserve_unlisted_links_by_default" {
  command = plan

  assert {
    condition = contains(
      [for l in wiz_project.projects["TestFolder/repo-project"].repository_links : l.repository],
      "repo-listed"
    )
    error_message = "A repo listed in the JSON should be linked"
  }

  assert {
    condition = contains(
      [for l in wiz_project.projects["TestFolder/repo-project"].repository_links : l.repository],
      "repo-manual"
    )
    error_message = "A manually added repo link not in the JSON should be preserved by default"
  }

  assert {
    condition = !contains(
      [for l in wiz_project.projects["TestFolder/repo-project"].repository_links : l.repository],
      "repo-other"
    )
    error_message = "Links from a different, fuzzy-matched project must not be pulled in"
  }

  assert {
    condition     = length(wiz_project.projects["TestFolder/repo-project"].repository_links) == 2
    error_message = "Expected exactly the listed link plus the preserved manual link (no duplicates)"
  }

  assert {
    condition     = output.unlisted_repo_links["TestFolder/repo-project"] == tolist(["repo-manual"])
    error_message = "unlisted_repo_links should report the manually added link"
  }
}

run "json_is_source_of_truth_when_disabled" {
  command = plan

  variables {
    preserve_unlisted_repo_links = false
  }

  assert {
    condition = !contains(
      [for l in wiz_project.projects["TestFolder/repo-project"].repository_links : l.repository],
      "repo-manual"
    )
    error_message = "With preserve_unlisted_repo_links = false, unlisted links should be removed"
  }

  assert {
    condition     = length(wiz_project.projects["TestFolder/repo-project"].repository_links) == 1
    error_message = "Only the JSON-listed link should remain"
  }

  assert {
    condition     = output.unlisted_repo_links["TestFolder/repo-project"] == tolist(["repo-manual"])
    error_message = "unlisted_repo_links should still report what is being removed"
  }
}
