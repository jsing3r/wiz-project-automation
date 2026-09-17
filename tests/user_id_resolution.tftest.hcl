# Run with: terraform test
#
# This mocks the wiz provider entirely, so it makes no real API calls and
# needs no real credentials. It injects three cases into the user lookup
# that you can't currently reproduce against your real tenant:
#   - good@example.com       -> a valid UUID (should be usable)
#   - badformat@example.com  -> resolves to a non-UUID ID, like the
#                                xx-sso_* case (should be filtered out)
#   - missing@example.com    -> resolves to no user at all (should be
#                                filtered out, and reported separately)

mock_provider "wiz" {}

variables {
  wiz_client_id     = "mock-client-id"
  wiz_client_secret = "mock-client-secret"
  json_import_file  = "tests/fixtures/test_import.json"
}

run "user_id_resolution" {
  command = plan

  override_data {
    target = data.wiz_users.lookup["good@example.com"]
    values = {
      wiz_users = [
        { id = "d290f1ee-6c54-4b01-90e6-d701748f0851", email = "good@example.com" }
      ]
    }
  }

  override_data {
    target = data.wiz_users.lookup["badformat@example.com"]
    values = {
      wiz_users = [
        { id = "xx-sso_jkldfgjioeruiertdrnfgierjtioerjriogjdriog", email = "badformat@example.com" }
      ]
    }
  }

  override_data {
    target = data.wiz_users.lookup["missing@example.com"]
    values = {
      wiz_users = []
    }
  }

  # --- resolved_user_ids: only the valid UUID survives ---
  assert {
    condition     = output.resolved_user_ids["good@example.com"] == "d290f1ee-6c54-4b01-90e6-d701748f0851"
    error_message = "A valid UUID should be kept in resolved_user_ids"
  }

  assert {
    condition     = output.resolved_user_ids["badformat@example.com"] == null
    error_message = "A non-UUID ID should be filtered out of resolved_user_ids"
  }

  assert {
    condition     = output.resolved_user_ids["missing@example.com"] == null
    error_message = "An unresolved user should be null in resolved_user_ids"
  }

  # --- reporting outputs distinguish the two failure modes ---
  assert {
    condition     = output.unusable_user_ids["badformat@example.com"] == "xx-sso_jkldfgjioeruiertdrnfgierjtioerjriogjdriog"
    error_message = "unusable_user_ids should report the raw non-UUID ID that got filtered"
  }

  assert {
    condition     = contains(output.unresolved_users, "missing@example.com")
    error_message = "unresolved_users should list the email that returned no user at all"
  }

  assert {
    condition     = !contains(output.unresolved_users, "badformat@example.com")
    error_message = "unresolved_users should NOT include an email that resolved, just unusably"
  }

  # --- end-to-end: the leaf project only ends up with the usable owner ---
  assert {
    condition     = contains(wiz_project.projects["TestFolder/test-project"].project_owners, "d290f1ee-6c54-4b01-90e6-d701748f0851")
    error_message = "The good user's UUID should end up in project_owners"
  }

  assert {
    condition     = length(wiz_project.projects["TestFolder/test-project"].project_owners) == 1
    error_message = "Only the one usable owner should survive filtering (badformat's admin role should be dropped)"
  }
}
