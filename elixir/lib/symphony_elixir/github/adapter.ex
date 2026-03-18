defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().post_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker
    prefix = tracker.state_label_prefix
    terminal_set = MapSet.new(tracker.terminal_states, &String.downcase/1)
    active_set = MapSet.new(tracker.active_states, &String.downcase/1)

    with {:ok, current_labels} <- client_module().get_issue_labels(issue_id) do
      non_state_labels = Enum.reject(current_labels, &String.starts_with?(&1, prefix))
      new_labels = non_state_labels ++ ["#{prefix}#{state_name}"]

      with :ok <- client_module().set_labels(issue_id, new_labels) do
        normalized = String.downcase(state_name)

        cond do
          MapSet.member?(terminal_set, normalized) ->
            client_module().close_issue(issue_id)

          MapSet.member?(active_set, normalized) ->
            # Reopen if it was closed
            client_module().reopen_issue(issue_id)

          true ->
            :ok
        end
      end
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
