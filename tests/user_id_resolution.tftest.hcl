# Run with: terraform test
#
# This mocks the wiz provider entirely, so it makes no real API calls and
# needs no real credentials.
#
# Earlier versions of this test asserted that a non-UUID resolved ID got
# filtered out of project_owners/security_champions. That assumption was
# disproven against a real Wiz tenant: Wiz's own UI assigns project
# ownership using exactly this non-UUID, idp-prefixed shape for SSO/SAML
# users (e.g. "comp-okta_<email>"), so ID shape is not a valid signal of
# usability. main.tf no longer filters by shape - the only thing that
# gets an email dropped from project_owners/security_champions is the
# wiz_users lookup finding no match at all.
#
# This test now covers:
#   - good@example.com    -> a UUID-shaped ID (should be usable)
#   - sso@example.com     -> a non-UUID, idp-prefixed ID, the same shape
#                            Wiz itself uses for SSO users (should ALSO
#                            be usable - this is the regression case)
#   - missing@example.com -> resolves to no user at all (should be the
#                            only one filtered out)

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
    target = data.wiz_users.lookup["sso@example.com"]
    values = {
      wiz_users = [
        { id = "comp-okta_sso@example.com", email = "sso@example.com" }
      ]
    }
  }

  override_data {
    target = data.wiz_users.lookup["missing@example.com"]
    values = {
      wiz_users = []
    }
  }

  # --- resolved_user_ids: any resolved ID is kept, regardless of shape ---
  assert {
    condition     = output.resolved_user_ids["good@example.com"] == "d290f1ee-6c54-4b01-90e6-d701748f0851"
    error_message = "A UUID-shaped ID should be kept in resolved_user_ids"
  }

  assert {
    condition     = output.resolved_user_ids["sso@example.com"] == "comp-okta_sso@example.com"
    error_message = "A non-UUID, idp-prefixed ID should ALSO be kept in resolved_user_ids - this is the real shape Wiz uses for SSO users"
  }

  assert {
    condition     = output.resolved_user_ids["missing@example.com"] == null
    error_message = "Only a fully-unresolved user should be null in resolved_user_ids"
  }

  # --- unresolved_users only reports the genuinely-unmatched email ---
  assert {
    condition     = contains(output.unresolved_users, "missing@example.com")
    error_message = "unresolved_users should list the email that returned no user at all"
  }

  assert {
    condition     = !contains(output.unresolved_users, "sso@example.com")
    error_message = "unresolved_users should NOT include an email that resolved, even to a non-UUID ID"
  }

  # --- end-to-end: both resolvable owners make it into project_owners ---
  assert {
    condition     = contains(wiz_project.projects["TestFolder/test-project"].project_owners, "d290f1ee-6c54-4b01-90e6-d701748f0851")
    error_message = "The UUID-shaped owner should end up in project_owners"
  }

  assert {
    condition     = contains(wiz_project.projects["TestFolder/test-project"].project_owners, "comp-okta_sso@example.com")
    error_message = "The non-UUID SSO owner should ALSO end up in project_owners"
  }

  assert {
    condition     = length(wiz_project.projects["TestFolder/test-project"].project_owners) == 2
    error_message = "Both admin-role users should survive - only the fully-unresolved user should be dropped"
  }
}
