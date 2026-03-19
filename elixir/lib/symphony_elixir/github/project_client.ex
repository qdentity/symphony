defmodule SymphonyElixir.GitHub.ProjectClient do
  @moduledoc """
  GraphQL client for GitHub Projects v2 status field operations.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec ensure_metadata() :: {:ok, map()} | {:error, term()}
  def ensure_metadata do
    tracker = Config.settings!().tracker
    cache_key = cache_key(tracker)

    case :persistent_term.get(cache_key, nil) do
      nil -> resolve_and_cache(cache_key, tracker)
      metadata -> {:ok, metadata}
    end
  end

  @spec fetch_project_status_map() :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def fetch_project_status_map do
    with {:ok, metadata} <- ensure_metadata() do
      tracker = Config.settings!().tracker
      fetch_all_project_items(metadata, tracker, nil, {%{}, 0})
    end
  end

  @spec fetch_issue_project_status(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_issue_project_status(issue_number) when is_binary(issue_number) do
    with {:ok, metadata} <- ensure_metadata() do
      tracker = Config.settings!().tracker
      {owner, repo} = Client.parse_slug!(tracker.project_slug)

      query = """
      query($owner: String!, $repo: String!, $number: Int!, $statusFieldName: String!) {
        repository(owner: $owner, name: $repo) {
          issue(number: $number) {
            projectItems(first: 50, includeArchived: false) {
              nodes {
                project { id }
                fieldValueByName(name: $statusFieldName) {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
              }
            }
          }
        }
      }
      """

      variables = %{
        "owner" => owner,
        "repo" => repo,
        "number" => String.to_integer(issue_number),
        "statusFieldName" => tracker.project_status_field
      }

      case graphql_request(query, variables) do
        {:ok, data} ->
          nodes = get_in(data, ["repository", "issue", "projectItems", "nodes"]) || []
          status = find_status_for_project(nodes, metadata.project_id)
          {:ok, status}

        {:error, _} = error ->
          error
      end
    end
  end

  @spec update_project_item_status(String.t(), String.t()) :: :ok | {:error, term()}
  def update_project_item_status(issue_number, state_name)
      when is_binary(issue_number) and is_binary(state_name) do
    with {:ok, metadata} <- ensure_metadata(),
         {:ok, item_id} <- find_project_item_id(issue_number, metadata),
         {:ok, option_id} <- resolve_option_id(state_name, metadata) do
      execute_status_mutation(metadata, item_id, option_id)
    end
  end

  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.get()
    |> Enum.each(fn
      {{__MODULE__, _, _, _, _} = key, _} -> :persistent_term.erase(key)
      _ -> :ok
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Metadata resolution
  # ---------------------------------------------------------------------------

  defp resolve_and_cache(cache_key, tracker) do
    {owner, _repo} = Client.parse_slug!(tracker.project_slug)

    case resolve_project_metadata(owner, tracker.project_number, tracker.project_status_field) do
      {:ok, metadata} ->
        metadata = Map.put(metadata, :cache_key, cache_key)
        :persistent_term.put(cache_key, metadata)
        {:ok, metadata}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_project_metadata(login, project_number, field_name) do
    query = """
    query($login: String!, $number: Int!, $fieldName: String!) {
      organization: organization(login: $login) {
        projectV2(number: $number) {
          id
          field(name: $fieldName) {
            __typename
            ... on ProjectV2SingleSelectField { id options { id name } }
          }
        }
      }
      user: user(login: $login) {
        projectV2(number: $number) {
          id
          field(name: $fieldName) {
            __typename
            ... on ProjectV2SingleSelectField { id options { id name } }
          }
        }
      }
    }
    """

    variables = %{"login" => login, "number" => project_number, "fieldName" => field_name}

    case graphql_request(query, variables) do
      {:ok, data} ->
        parse_project_metadata(data)

      {:error, _} = error ->
        error
    end
  end

  defp parse_project_metadata(data) do
    project =
      get_in(data, ["organization", "projectV2"]) ||
        get_in(data, ["user", "projectV2"])

    cond do
      is_nil(project) ->
        {:error, :project_not_found}

      is_nil(project["field"]) ->
        {:error, :status_field_not_found}

      project["field"]["__typename"] != "ProjectV2SingleSelectField" ->
        {:error, :status_field_not_single_select}

      true ->
        build_metadata(project)
    end
  end

  defp build_metadata(project) do
    field = project["field"]
    raw_options = field["options"] || []

    options =
      Map.new(raw_options, fn %{"id" => id, "name" => name} ->
        {String.downcase(name), id}
      end)

    if map_size(options) < length(raw_options) do
      {:error, :duplicate_status_options}
    else
      {:ok,
       %{
         project_id: project["id"],
         field_id: field["id"],
         options: options
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Status map (full board scan)
  # ---------------------------------------------------------------------------

  # acc: {status_map, matched_issue_count}
  defp fetch_all_project_items(metadata, tracker, cursor, acc) do
    query = """
    query($projectId: ID!, $statusFieldName: String!, $after: String) {
      node(id: $projectId) {
        ... on ProjectV2 {
          items(first: 100, after: $after) {
            nodes {
              fieldValueByName(name: $statusFieldName) {
                ... on ProjectV2ItemFieldSingleSelectValue { name }
              }
              content {
                __typename
                ... on Issue { number repository { nameWithOwner } }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """

    variables =
      %{"projectId" => metadata.project_id, "statusFieldName" => tracker.project_status_field}
      |> maybe_put("after", cursor)

    case graphql_request(query, variables) do
      {:ok, data} ->
        items = get_in(data, ["node", "items"]) || %{}
        nodes = items["nodes"] || []
        page_info = items["pageInfo"] || %{}

        new_acc = process_status_nodes(nodes, tracker.project_slug, acc)

        if page_info["hasNextPage"] do
          fetch_all_project_items(metadata, tracker, page_info["endCursor"], new_acc)
        else
          {status_map, matched_count} = new_acc
          maybe_warn_no_statuses(status_map, matched_count)
          {:ok, status_map}
        end

      {:error, _} = error ->
        error
    end
  end

  defp process_status_nodes(nodes, project_slug, acc) do
    slug_downcased = String.downcase(project_slug)
    Enum.reduce(nodes, acc, &process_status_node(&1, slug_downcased, &2))
  end

  defp process_status_node(node, slug_downcased, {map, count}) do
    with %{"__typename" => "Issue", "number" => number, "repository" => %{"nameWithOwner" => repo}} <-
           node["content"],
         true <- String.downcase(repo) == slug_downcased do
      case node["fieldValueByName"] do
        %{"name" => status_name} -> {Map.put(map, to_string(number), status_name), count + 1}
        _ -> {map, count + 1}
      end
    else
      _ -> {map, count}
    end
  end

  defp maybe_warn_no_statuses(_map, 0), do: :ok

  defp maybe_warn_no_statuses(map, matched_count) when matched_count > 0 and map_size(map) == 0 do
    Logger.warning(
      "GitHub Projects: #{matched_count} matching issues found but none have a status value — " <>
        "status field may have been renamed or misconfigured"
    )
  end

  defp maybe_warn_no_statuses(_map, _matched_count), do: :ok

  # ---------------------------------------------------------------------------
  # Write path: update status
  # ---------------------------------------------------------------------------

  defp find_project_item_id(issue_number, metadata) do
    tracker = Config.settings!().tracker
    {owner, repo} = Client.parse_slug!(tracker.project_slug)

    query = """
    query($owner: String!, $repo: String!, $issueNumber: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $issueNumber) {
          projectItems(first: 50, includeArchived: false) {
            nodes { id project { id } }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """

    variables = %{
      "owner" => owner,
      "repo" => repo,
      "issueNumber" => String.to_integer(issue_number)
    }

    case graphql_request(query, variables) do
      {:ok, data} ->
        nodes = get_in(data, ["repository", "issue", "projectItems", "nodes"]) || []
        find_matching_item(nodes, metadata.project_id)

      {:error, _} = error ->
        error
    end
  end

  defp find_matching_item(nodes, project_id) do
    case Enum.find(nodes, fn node -> get_in(node, ["project", "id"]) == project_id end) do
      %{"id" => item_id} -> {:ok, item_id}
      nil -> {:error, :issue_not_on_project}
    end
  end

  defp resolve_option_id(state_name, metadata) do
    downcased = String.downcase(state_name)

    case Map.get(metadata.options, downcased) do
      nil -> retry_option_after_cache_clear(state_name, downcased)
      option_id -> {:ok, option_id}
    end
  end

  defp retry_option_after_cache_clear(state_name, downcased) do
    clear_cache()

    case ensure_metadata() do
      {:ok, fresh} ->
        case Map.get(fresh.options, downcased) do
          nil ->
            Logger.warning("Unknown project status option: #{inspect(state_name)}")
            {:error, :unknown_status_option}

          option_id ->
            {:ok, option_id}
        end

      {:error, _} = error ->
        error
    end
  end

  defp execute_status_mutation(metadata, item_id, option_id) do
    mutation = """
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: { singleSelectOptionId: $optionId }
      }) {
        projectV2Item { id }
      }
    }
    """

    variables = %{
      "projectId" => metadata.project_id,
      "itemId" => item_id,
      "fieldId" => metadata.field_id,
      "optionId" => option_id
    }

    case graphql_request(mutation, variables) do
      {:ok, _data} -> :ok
      {:error, _} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # GraphQL transport
  # ---------------------------------------------------------------------------

  defp graphql_request(query, variables) do
    Client.api_request(:post, "/graphql", %{"query" => query, "variables" => variables})
    |> parse_graphql_response()
  end

  defp parse_graphql_response({:ok, %{status: 200, body: %{"data" => data, "errors" => errors}}})
       when is_map(data) and is_list(errors) and errors != [] do
    Logger.warning("GraphQL partial errors: #{inspect(errors)}")
    {:ok, data}
  end

  defp parse_graphql_response({:ok, %{status: 200, body: %{"errors" => errors}}})
       when is_list(errors) and errors != [] do
    {:error, {:graphql_errors, errors}}
  end

  defp parse_graphql_response({:ok, %{status: 200, body: %{"data" => data}}}), do: {:ok, data}

  defp parse_graphql_response({:ok, %{status: 200, body: body}}),
    do: {:error, {:graphql_unexpected_body, body}}

  defp parse_graphql_response({:ok, %{status: status}}),
    do: {:error, {:github_api_status, status}}

  defp parse_graphql_response({:error, reason}),
    do: {:error, {:github_api_request, reason}}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp find_status_for_project(nodes, project_id) do
    case Enum.find(nodes, fn node -> get_in(node, ["project", "id"]) == project_id end) do
      %{"fieldValueByName" => %{"name" => name}} -> name
      _ -> nil
    end
  end

  defp cache_key(tracker) do
    {owner, _repo} = Client.parse_slug!(tracker.project_slug)
    {__MODULE__, tracker.endpoint, owner, tracker.project_number, tracker.project_status_field}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
