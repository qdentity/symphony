defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  REST client for GitHub Issues used by the GitHub tracker adapter.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @per_page 100
  @github_api_version "2022-11-28"

  # ---------------------------------------------------------------------------
  # Read callbacks
  # ---------------------------------------------------------------------------

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_github_api_token}

      is_nil(tracker.project_slug) ->
        {:error, :missing_github_repository}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          active_set = state_name_set(tracker.active_states)
          prefix = tracker.state_label_prefix

          fetch_open_issues(tracker, assignee_filter)
          |> filter_by_state_labels(active_set, prefix, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_github_api_token}

        is_nil(tracker.project_slug) ->
          {:error, :missing_github_repository}

        true ->
          with {:ok, assignee_filter} <- routing_assignee_filter() do
            state_set = state_name_set(normalized)
            prefix = tracker.state_label_prefix

            fetch_all_issues(tracker)
            |> filter_by_state_labels(state_set, prefix, assignee_filter)
          end
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    if ids == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with {:ok, assignee_filter} <- routing_assignee_filter() do
        fetch_issues_individually(ids, tracker, assignee_filter)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Write helpers (used by adapter)
  # ---------------------------------------------------------------------------

  @spec post_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def post_comment(issue_number, body) when is_binary(issue_number) and is_binary(body) do
    tracker = Config.settings!().tracker
    {owner, repo} = parse_slug!(tracker.project_slug)
    path = "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

    case api_request(:post, path, %{"body" => body}) do
      {:ok, %{status: 201}} -> :ok
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  @spec set_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def set_labels(issue_number, label_names) when is_binary(issue_number) and is_list(label_names) do
    tracker = Config.settings!().tracker
    {owner, repo} = parse_slug!(tracker.project_slug)
    path = "/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"

    case api_request(:put, path, %{"labels" => label_names}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  @spec close_issue(String.t()) :: :ok | {:error, term()}
  def close_issue(issue_number) when is_binary(issue_number) do
    tracker = Config.settings!().tracker
    {owner, repo} = parse_slug!(tracker.project_slug)
    path = "/repos/#{owner}/#{repo}/issues/#{issue_number}"

    case api_request(:patch, path, %{"state" => "closed"}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  @spec reopen_issue(String.t()) :: :ok | {:error, term()}
  def reopen_issue(issue_number) when is_binary(issue_number) do
    tracker = Config.settings!().tracker
    {owner, repo} = parse_slug!(tracker.project_slug)
    path = "/repos/#{owner}/#{repo}/issues/#{issue_number}"

    case api_request(:patch, path, %{"state" => "open"}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  @spec get_issue_labels(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_issue_labels(issue_number) when is_binary(issue_number) do
    tracker = Config.settings!().tracker
    {owner, repo} = parse_slug!(tracker.project_slug)
    path = "/repos/#{owner}/#{repo}/issues/#{issue_number}/labels"

    case paginated_get(path) do
      {:ok, labels} ->
        {:ok, Enum.map(labels, & &1["name"])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec ensure_state_labels() :: :ok
  def ensure_state_labels do
    tracker = Config.settings!().tracker
    {owner, repo} = parse_slug!(tracker.project_slug)
    prefix = tracker.state_label_prefix

    existing =
      case paginated_get("/repos/#{owner}/#{repo}/labels") do
        {:ok, labels} -> MapSet.new(labels, & &1["name"])
        {:error, _} -> MapSet.new()
      end

    all_states = tracker.active_states ++ tracker.terminal_states

    Enum.each(all_states, fn state_name ->
      label_name = "#{prefix}#{state_name}"

      unless MapSet.member?(existing, label_name) do
        body = %{
          "name" => label_name,
          "color" => "1d76db",
          "description" => "Symphony state"
        }

        case api_request(:post, "/repos/#{owner}/#{repo}/labels", body) do
          {:ok, %{status: status}} when status in [201, 422] ->
            :ok

          {:ok, %{status: status}} ->
            Logger.warning("Failed to create label #{label_name}: HTTP #{status}")

          {:error, reason} ->
            Logger.warning("Failed to create label #{label_name}: #{inspect(reason)}")
        end
      end
    end)

    :ok
  end

  @doc """
  Execute a raw REST API request through Symphony's configured GitHub auth.
  Used by the github_api dynamic tool.
  """
  @spec api_request(atom(), String.t(), map() | nil) :: {:ok, map()} | {:error, term()}
  def api_request(method, path, body \\ nil) do
    tracker = Config.settings!().tracker

    case tracker.api_key do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        url = String.trim_trailing(tracker.endpoint, "/") <> path
        request_fun = Application.get_env(:symphony_elixir, :github_request_fun, &do_request/3)
        request_fun.(method, url, {token, body})
    end
  end

  # ---------------------------------------------------------------------------
  # Internal fetch helpers
  # ---------------------------------------------------------------------------

  defp fetch_open_issues(tracker, assignee_filter) do
    {owner, repo} = parse_slug!(tracker.project_slug)
    path = "/repos/#{owner}/#{repo}/issues?state=open&per_page=#{@per_page}"

    path =
      case assignee_filter do
        %{configured_assignee: username} when is_binary(username) and username != "me" ->
          path <> "&assignee=#{URI.encode_www_form(username)}"

        _ ->
          path
      end

    paginated_get(path)
  end

  defp fetch_all_issues(tracker) do
    {owner, repo} = parse_slug!(tracker.project_slug)
    path = "/repos/#{owner}/#{repo}/issues?state=all&per_page=#{@per_page}"
    paginated_get(path)
  end

  defp filter_by_state_labels({:ok, raw_issues}, state_set, prefix, assignee_filter) do
    issues =
      raw_issues
      |> Enum.reject(&is_pull_request?/1)
      |> Enum.map(&normalize_issue(&1, prefix, assignee_filter))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn issue ->
        issue.state != nil and MapSet.member?(state_set, String.downcase(issue.state))
      end)

    {:ok, issues}
  end

  defp filter_by_state_labels({:error, _} = error, _state_set, _prefix, _assignee_filter), do: error

  defp fetch_issues_individually(ids, tracker, assignee_filter) do
    {owner, repo} = parse_slug!(tracker.project_slug)
    prefix = tracker.state_label_prefix

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      path = "/repos/#{owner}/#{repo}/issues/#{id}"

      case api_request(:get, path) do
        {:ok, %{status: 200, body: body}} ->
          case normalize_issue(body, prefix, assignee_filter) do
            nil -> {:cont, {:ok, acc}}
            issue -> {:cont, {:ok, acc ++ [issue]}}
          end

        {:ok, %{status: status}} when status in [404, 410] ->
          {:cont, {:ok, acc}}

        {:ok, %{status: status}} when status in [403, 429] ->
          Logger.error("GitHub API rate limited: HTTP #{status}")
          {:halt, {:error, {:github_api_status, status}}}

        {:ok, %{status: status}} ->
          {:halt, {:error, {:github_api_status, status}}}

        {:error, reason} ->
          {:halt, {:error, {:github_api_request, reason}}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Normalization
  # ---------------------------------------------------------------------------

  defp normalize_issue(issue, prefix, assignee_filter) when is_map(issue) do
    number = issue["number"]
    return_nil? = is_nil(number)

    if return_nil? do
      nil
    else
      number_str = to_string(number)
      repo_name = repo_name_from_slug()
      github_state = issue["state"]
      labels = issue["labels"] || []
      label_names = Enum.map(labels, & &1["name"])

      {state_labels, non_state_labels} =
        Enum.split_with(label_names, &String.starts_with?(&1, prefix))

      state = determine_state(github_state, state_labels, prefix)

      if length(state_labels) > 1 do
        Logger.warning(
          "Issue ##{number_str} has multiple state labels: #{inspect(state_labels)}; using first alphabetically"
        )
      end

      %Issue{
        id: number_str,
        identifier: "#{repo_name}##{number_str}",
        title: issue["title"],
        description: issue["body"],
        priority: nil,
        state: state,
        branch_name: nil,
        url: issue["html_url"],
        assignee_id: get_in(issue, ["assignee", "login"]),
        blocked_by: [],
        labels: Enum.map(non_state_labels, &String.downcase/1),
        assigned_to_worker: assigned_to_worker?(issue, assignee_filter),
        created_at: parse_datetime(issue["created_at"]),
        updated_at: parse_datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_issue, _prefix, _assignee_filter), do: nil

  defp determine_state("closed", state_labels, prefix) do
    case Enum.sort(state_labels) do
      [first | _] -> String.trim_leading(first, prefix)
      [] -> nil
    end
  end

  defp determine_state(_open, state_labels, prefix) do
    case Enum.sort(state_labels) do
      [first | _] -> String.trim_leading(first, prefix)
      [] -> nil
    end
  end

  defp is_pull_request?(issue), do: is_map(issue["pull_request"])

  defp assigned_to_worker?(_issue, nil), do: true

  defp assigned_to_worker?(issue, %{match_values: match_values}) when is_struct(match_values, MapSet) do
    assignees = issue["assignees"] || []

    logins =
      if assignees == [] do
        case issue["assignee"] do
          %{"login" => login} when is_binary(login) -> [login]
          _ -> []
        end
      else
        Enum.map(assignees, & &1["login"]) |> Enum.reject(&is_nil/1)
      end

    Enum.any?(logins, &MapSet.member?(match_values, &1))
  end

  defp assigned_to_worker?(_issue, _assignee_filter), do: false

  # ---------------------------------------------------------------------------
  # Assignee routing
  # ---------------------------------------------------------------------------

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil -> {:ok, nil}
      assignee -> build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case String.trim(assignee) do
      "" ->
        {:ok, nil}

      "me" ->
        resolve_authenticated_user_filter()

      username ->
        {:ok, %{configured_assignee: username, match_values: MapSet.new([username])}}
    end
  end

  defp resolve_authenticated_user_filter do
    case api_request(:get, "/user") do
      {:ok, %{status: 200, body: %{"login" => login}}} when is_binary(login) ->
        {:ok, %{configured_assignee: "me", match_values: MapSet.new([login])}}

      {:ok, _} ->
        {:error, :missing_github_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helpers
  # ---------------------------------------------------------------------------

  defp paginated_get(path) do
    paginated_get(path, [])
  end

  defp paginated_get(path, acc) do
    case api_request(:get, path) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        updated = acc ++ body

        case next_page_url(headers) do
          nil -> {:ok, updated}
          next_url -> paginated_get_url(next_url, updated)
        end

      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, acc ++ body}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp paginated_get_url(full_url, acc) do
    request_fun = Application.get_env(:symphony_elixir, :github_request_fun, &do_request/3)
    tracker = Config.settings!().tracker

    case request_fun.(:get, full_url, {tracker.api_key, nil}) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        updated = acc ++ body

        case next_page_url(headers) do
          nil -> {:ok, updated}
          next_url -> paginated_get_url(next_url, updated)
        end

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp next_page_url(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"link", value} -> value
      _ -> nil
    end)
    |> parse_link_header_next()
  end

  defp next_page_url(_), do: nil

  defp parse_link_header_next(nil), do: nil

  defp parse_link_header_next(link_header) when is_binary(link_header) do
    link_header
    |> String.split(",")
    |> Enum.find_value(fn part ->
      if String.contains?(part, ~s(rel="next")) do
        case Regex.run(~r/<([^>]+)>/, part) do
          [_, url] -> url
          _ -> nil
        end
      end
    end)
  end

  defp do_request(method, url, {token, body}) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Accept", "application/vnd.github+json"},
      {"User-Agent", "symphony-elixir"},
      {"X-GitHub-Api-Version", @github_api_version}
    ]

    opts = [
      headers: headers,
      connect_options: [timeout: 30_000]
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case apply(Req, method, [url, opts]) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
        flat_headers =
          Enum.flat_map(resp_headers, fn
            {key, values} when is_list(values) -> Enum.map(values, &{key, &1})
            {key, value} -> [{key, value}]
          end)

        {:ok, %{status: status, body: resp_body, headers: flat_headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Utility
  # ---------------------------------------------------------------------------

  defp parse_slug!(slug) when is_binary(slug) do
    case String.split(slug, "/", parts: 2) do
      [owner, repo] -> {owner, repo}
      _ -> raise "Invalid project_slug: #{inspect(slug)}, expected owner/repo"
    end
  end

  defp repo_name_from_slug do
    case Config.settings!().tracker.project_slug do
      slug when is_binary(slug) ->
        case String.split(slug, "/", parts: 2) do
          [_owner, repo] -> repo
          _ -> slug
        end

      _ ->
        "unknown"
    end
  end

  defp state_name_set(state_names) do
    MapSet.new(state_names, &String.downcase/1)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
