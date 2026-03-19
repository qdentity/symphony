defmodule SymphonyElixir.GitHubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter

  defmodule FakeProjectClient do
    def update_project_item_status(issue_id, state_name) do
      send(self(), {:project_update_status, issue_id, state_name})
      Process.get({__MODULE__, :update_result}, :ok)
    end

    def fetch_project_status_map do
      send(self(), :project_fetch_status_map)
      Process.get({__MODULE__, :status_map_result}, {:ok, %{}})
    end

    def fetch_issue_project_status(issue_number) do
      send(self(), {:project_fetch_issue_status, issue_number})
      Process.get({__MODULE__, :issue_status_result}, {:ok, nil})
    end
  end

  defmodule FakeGitHubClient do
    def fetch_candidate_issues do
      send(self(), :gh_fetch_candidate_issues_called)
      {:ok, Process.get({__MODULE__, :candidate_issues}, [])}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:gh_fetch_issues_by_states_called, states})
      {:ok, Process.get({__MODULE__, :issues_by_states}, [])}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:gh_fetch_issue_states_by_ids_called, issue_ids})
      {:ok, Process.get({__MODULE__, :issue_states_by_ids}, [])}
    end

    def post_comment(issue_number, body) do
      send(self(), {:gh_post_comment, issue_number, body})
      Process.get({__MODULE__, :post_comment_result}, :ok)
    end

    def get_issue_labels(issue_number) do
      send(self(), {:gh_get_issue_labels, issue_number})
      Process.get({__MODULE__, :get_issue_labels_result}, {:ok, []})
    end

    def set_labels(issue_number, labels) do
      send(self(), {:gh_set_labels, issue_number, labels})
      Process.get({__MODULE__, :set_labels_result}, :ok)
    end

    def close_issue(issue_number) do
      send(self(), {:gh_close_issue, issue_number})
      Process.get({__MODULE__, :close_issue_result}, :ok)
    end

    def reopen_issue(issue_number) do
      send(self(), {:gh_reopen_issue, issue_number})
      Process.get({__MODULE__, :reopen_issue_result}, :ok)
    end
  end

  setup do
    github_client_module = Application.get_env(:symphony_elixir, :github_client_module)
    project_client_module = Application.get_env(:symphony_elixir, :github_project_client_module)

    on_exit(fn ->
      if is_nil(github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, github_client_module)
      end

      if is_nil(project_client_module) do
        Application.delete_env(:symphony_elixir, :github_project_client_module)
      else
        Application.put_env(:symphony_elixir, :github_project_client_module, project_client_module)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo"
    )

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_project_client_module, FakeProjectClient)
    :ok
  end

  # -------------------------------------------------------------------------
  # Tracker routing
  # -------------------------------------------------------------------------

  test "tracker routes to GitHub.Adapter when kind is github" do
    assert Tracker.adapter() == GitHubAdapter
  end

  # -------------------------------------------------------------------------
  # Read delegation
  # -------------------------------------------------------------------------

  test "adapter delegates fetch_candidate_issues to client" do
    assert {:ok, []} = GitHubAdapter.fetch_candidate_issues()
    assert_receive :gh_fetch_candidate_issues_called
  end

  test "adapter delegates fetch_issues_by_states to client" do
    assert {:ok, []} = GitHubAdapter.fetch_issues_by_states(["Todo", "Done"])
    assert_receive {:gh_fetch_issues_by_states_called, ["Todo", "Done"]}
  end

  test "adapter delegates fetch_issue_states_by_ids to client" do
    assert {:ok, []} = GitHubAdapter.fetch_issue_states_by_ids(["42", "99"])
    assert_receive {:gh_fetch_issue_states_by_ids_called, ["42", "99"]}
  end

  # -------------------------------------------------------------------------
  # Write: create_comment
  # -------------------------------------------------------------------------

  test "create_comment delegates to post_comment" do
    assert :ok = GitHubAdapter.create_comment("42", "Hello world")
    assert_receive {:gh_post_comment, "42", "Hello world"}
  end

  test "create_comment propagates errors" do
    Process.put({FakeGitHubClient, :post_comment_result}, {:error, {:github_api_status, 403}})
    assert {:error, {:github_api_status, 403}} = GitHubAdapter.create_comment("42", "nope")
  end

  # -------------------------------------------------------------------------
  # Write: update_issue_state
  # -------------------------------------------------------------------------

  test "update_issue_state sets labels with prefix and preserves non-state labels" do
    Process.put({FakeGitHubClient, :get_issue_labels_result}, {:ok, ["bug", "state/Todo"]})

    assert :ok = GitHubAdapter.update_issue_state("42", "In Progress")

    assert_receive {:gh_get_issue_labels, "42"}
    assert_receive {:gh_set_labels, "42", labels}
    assert "bug" in labels
    assert "state/In Progress" in labels
    refute "state/Todo" in labels
  end

  test "update_issue_state to terminal state also closes issue" do
    Process.put({FakeGitHubClient, :get_issue_labels_result}, {:ok, ["state/In Progress"]})

    assert :ok = GitHubAdapter.update_issue_state("42", "Done")

    assert_receive {:gh_set_labels, "42", ["state/Done"]}
    assert_receive {:gh_close_issue, "42"}
  end

  test "update_issue_state to active state reopens issue" do
    Process.put({FakeGitHubClient, :get_issue_labels_result}, {:ok, ["state/Done"]})

    assert :ok = GitHubAdapter.update_issue_state("42", "Todo")

    assert_receive {:gh_set_labels, "42", ["state/Todo"]}
    assert_receive {:gh_reopen_issue, "42"}
  end

  # -------------------------------------------------------------------------
  # Config validation
  # -------------------------------------------------------------------------

  test "config accepts kind github" do
    assert {:ok, settings} = Config.settings()
    assert settings.tracker.kind == "github"
  end

  test "config rejects github without api_key" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: nil,
      tracker_project_slug: "owner/repo"
    )

    assert {:error, :missing_github_api_token} = Config.validate!()
  end

  test "config rejects github without project_slug" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: nil
    )

    assert {:error, :missing_github_repository} = Config.validate!()
  end

  test "config rejects github project_slug without slash" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "noslash"
    )

    assert {:error, :missing_github_repository} = Config.validate!()
  end

  # -------------------------------------------------------------------------
  # Env var resolution
  # -------------------------------------------------------------------------

  test "github tracker falls back to GITHUB_TOKEN env var" do
    previous = System.get_env("GITHUB_TOKEN")

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous) end)

    System.put_env("GITHUB_TOKEN", "env_token_val")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: nil,
      tracker_project_slug: "owner/repo"
    )

    assert {:ok, settings} = Config.settings()
    assert settings.tracker.api_key == "env_token_val"
  end

  test "github tracker falls back to GITHUB_ASSIGNEE env var" do
    previous = System.get_env("GITHUB_ASSIGNEE")

    on_exit(fn -> restore_env("GITHUB_ASSIGNEE", previous) end)

    System.put_env("GITHUB_ASSIGNEE", "octocat")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_assignee: nil
    )

    assert {:ok, settings} = Config.settings()
    assert settings.tracker.assignee == "octocat"
  end

  # -------------------------------------------------------------------------
  # Endpoint default
  # -------------------------------------------------------------------------

  test "github tracker defaults endpoint to https://api.github.com" do
    assert {:ok, settings} = Config.settings()
    assert settings.tracker.endpoint == "https://api.github.com"
  end

  test "github tracker preserves explicit endpoint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_endpoint: "https://ghes.example.com/api/v3"
    )

    assert {:ok, settings} = Config.settings()
    assert settings.tracker.endpoint == "https://ghes.example.com/api/v3"
  end

  # -------------------------------------------------------------------------
  # State label prefix
  # -------------------------------------------------------------------------

  test "state_label_prefix defaults to state/" do
    assert {:ok, settings} = Config.settings()
    assert settings.tracker.state_label_prefix == "state/"
  end

  # -------------------------------------------------------------------------
  # state_source config
  # -------------------------------------------------------------------------

  test "state_source defaults to labels" do
    assert {:ok, settings} = Config.settings()
    assert settings.tracker.state_source == "labels"
  end

  test "state_source project is accepted with project_number" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_state_source: "project",
      tracker_project_number: 3
    )

    assert {:ok, settings} = Config.settings()
    assert settings.tracker.state_source == "project"
    assert settings.tracker.project_number == 3
  end

  test "state_source project without project_number is rejected" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_state_source: "project"
    )

    assert {:error, :missing_github_project_number} = Config.validate!()
  end

  test "project_status_field defaults to Status" do
    assert {:ok, settings} = Config.settings()
    assert settings.tracker.project_status_field == "Status"
  end

  # -------------------------------------------------------------------------
  # Write: update_issue_state with project mode
  # -------------------------------------------------------------------------

  test "update_issue_state in project mode calls project client, not labels" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_state_source: "project",
      tracker_project_number: 3
    )

    assert :ok = GitHubAdapter.update_issue_state("42", "In Progress")

    assert_receive {:project_update_status, "42", "In Progress"}
    # Should NOT touch labels
    refute_receive {:gh_get_issue_labels, _}
    refute_receive {:gh_set_labels, _, _}
    # Should still reopen (active state)
    assert_receive {:gh_reopen_issue, "42"}
  end

  test "update_issue_state in project mode to terminal state closes issue" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_state_source: "project",
      tracker_project_number: 3
    )

    assert :ok = GitHubAdapter.update_issue_state("42", "Done")

    assert_receive {:project_update_status, "42", "Done"}
    assert_receive {:gh_close_issue, "42"}
  end

  test "update_issue_state in project mode with issue_not_on_project still syncs github state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_state_source: "project",
      tracker_project_number: 3
    )

    Process.put({FakeProjectClient, :update_result}, {:error, :issue_not_on_project})

    assert :ok =
             capture_log(fn ->
               assert :ok = GitHubAdapter.update_issue_state("42", "Done")
             end)
             |> then(fn log ->
               assert log =~ "not on project board"
               :ok
             end)

    assert_receive {:gh_close_issue, "42"}
  end

  test "update_issue_state in project mode propagates project client errors" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_state_source: "project",
      tracker_project_number: 3
    )

    Process.put({FakeProjectClient, :update_result}, {:error, {:graphql_errors, ["oops"]}})

    assert {:error, {:graphql_errors, ["oops"]}} = GitHubAdapter.update_issue_state("42", "Done")
    refute_receive {:gh_close_issue, _}
  end
end
