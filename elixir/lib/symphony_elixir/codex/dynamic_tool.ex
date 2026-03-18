defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @github_api_tool "github_api"

  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @github_api_description """
  Execute a REST API request against GitHub using Symphony's configured auth.
  """
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => ["GET", "POST", "PATCH", "PUT", "DELETE"],
        "description" => "HTTP method for the GitHub API request."
      },
      "path" => %{
        "type" => "string",
        "description" => "API path (e.g. /repos/owner/repo/issues)."
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON request body.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    tracker_kind = current_tracker_kind()

    case {tool, tracker_kind} do
      {@linear_graphql_tool, "linear"} ->
        execute_linear_graphql(arguments, opts)

      {@github_api_tool, "github"} ->
        execute_github_api(arguments, opts)

      {@linear_graphql_tool, other} ->
        failure_response(%{
          "error" => %{
            "message" => "Tool `linear_graphql` is not available when tracker kind is #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })

      {@github_api_tool, other} ->
        failure_response(%{
          "error" => %{
            "message" => "Tool `github_api` is not available when tracker kind is #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })

      {other, _} ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case current_tracker_kind() do
      "linear" ->
        [linear_graphql_spec()]

      "github" ->
        [github_api_spec()]

      _ ->
        []
    end
  end

  defp linear_graphql_spec do
    %{
      "name" => @linear_graphql_tool,
      "description" => @linear_graphql_description,
      "inputSchema" => @linear_graphql_input_schema
    }
  end

  defp github_api_spec do
    %{
      "name" => @github_api_tool,
      "description" => @github_api_description,
      "inputSchema" => @github_api_input_schema
    }
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &SymphonyElixir.GitHub.Client.api_request/3)

    case normalize_github_api_arguments(arguments) do
      {:ok, method, path, body} ->
        case github_client.(method, path, body) do
          {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
            rest_response(resp_body)

          {:ok, %{status: status, body: resp_body}} ->
            failure_response(%{
              "error" => %{
                "message" => "GitHub API request failed with HTTP #{status}.",
                "status" => status,
                "body" => resp_body
              }
            })

          {:error, reason} ->
            failure_response(tool_error_payload({:github_api_request, reason}))
        end

      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_github_api_arguments(arguments) when is_map(arguments) do
    method_str = Map.get(arguments, "method") || Map.get(arguments, :method)
    path = Map.get(arguments, "path") || Map.get(arguments, :path)
    body = Map.get(arguments, "body") || Map.get(arguments, :body)

    cond do
      not is_binary(method_str) or String.trim(method_str) == "" ->
        {:error, :missing_github_method}

      not is_binary(path) or String.trim(path) == "" ->
        {:error, :missing_github_path}

      true ->
        method =
          method_str
          |> String.trim()
          |> String.downcase()
          |> String.to_existing_atom()

        {:ok, method, String.trim(path), body}
    end
  end

  defp normalize_github_api_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp rest_response(response) do
    dynamic_tool_response(true, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:missing_github_method) do
    %{
      "error" => %{
        "message" => "`github_api` requires a non-empty `method` string (GET, POST, PATCH, PUT, DELETE)."
      }
    }
  end

  defp tool_error_payload(:missing_github_path) do
    %{
      "error" => %{
        "message" => "`github_api` requires a non-empty `path` string."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp current_tracker_kind do
    Config.settings!().tracker.kind
  rescue
    _ -> "linear"
  end
end
