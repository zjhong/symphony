defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Linear.Client, Redmine}

  @linear_graphql_tool "linear_graphql"
  @redmine_update_issue_tool "redmine_update_issue"
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
  @redmine_update_issue_description """
  Add notes and/or change status on a Redmine issue using Symphony's configured Redmine auth.
  """
  @redmine_update_issue_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Redmine issue id, for example 2100."
      },
      "notes" => %{
        "type" => ["string", "null"],
        "description" => "Comment text to append to the Redmine issue."
      },
      "status_name" => %{
        "type" => ["string", "null"],
        "description" => "Redmine status name to set, for example 进行中 or 已解决."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @redmine_update_issue_tool ->
        execute_redmine_update_issue(arguments, opts)

      other ->
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
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @redmine_update_issue_tool,
        "description" => @redmine_update_issue_description,
        "inputSchema" => @redmine_update_issue_input_schema
      }
    ]
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

  defp execute_redmine_update_issue(arguments, opts) do
    redmine_update_issue = Keyword.get(opts, :redmine_update_issue, &Redmine.Client.update_issue/2)

    redmine_resolve_status_id =
      Keyword.get(opts, :redmine_resolve_status_id, &Redmine.Client.resolve_status_id/1)

    with {:ok, issue_id, fields} <-
           normalize_redmine_update_issue_arguments(arguments, redmine_resolve_status_id),
         :ok <- redmine_update_issue.(issue_id, fields) do
      dynamic_tool_response(true, encode_payload(%{"ok" => true, "issue_id" => issue_id}))
    else
      {:error, reason} ->
        failure_response(redmine_tool_error_payload(reason))
    end
  end

  defp normalize_redmine_update_issue_arguments(arguments, resolve_status_id)
       when is_map(arguments) and is_function(resolve_status_id, 1) do
    with {:ok, issue_id} <- normalize_redmine_issue_id(arguments),
         {:ok, fields} <- normalize_redmine_update_fields(arguments, resolve_status_id) do
      {:ok, issue_id, fields}
    end
  end

  defp normalize_redmine_update_issue_arguments(_arguments, _resolve_status_id),
    do: {:error, :invalid_redmine_arguments}

  defp normalize_redmine_issue_id(arguments) do
    case Map.get(arguments, "issue_id") || Map.get(arguments, :issue_id) do
      issue_id when is_binary(issue_id) ->
        case String.trim(issue_id) do
          "" -> {:error, :missing_redmine_issue_id}
          trimmed -> {:ok, trimmed}
        end

      issue_id when is_integer(issue_id) ->
        {:ok, to_string(issue_id)}

      _ ->
        {:error, :missing_redmine_issue_id}
    end
  end

  defp normalize_redmine_update_fields(arguments, resolve_status_id) do
    fields = %{}
    fields = maybe_put_notes(fields, Map.get(arguments, "notes") || Map.get(arguments, :notes))

    with {:ok, fields} <-
           maybe_put_status_id(
             fields,
             Map.get(arguments, "status_name") || Map.get(arguments, :status_name),
             resolve_status_id
           ) do
      if map_size(fields) == 0 do
        {:error, :missing_redmine_update_fields}
      else
        {:ok, fields}
      end
    end
  end

  defp maybe_put_notes(fields, notes) when is_binary(notes) do
    case String.trim(notes) do
      "" -> fields
      trimmed -> Map.put(fields, "notes", trimmed)
    end
  end

  defp maybe_put_notes(fields, _notes), do: fields

  defp maybe_put_status_id(fields, status_name, resolve_status_id) when is_binary(status_name) do
    case String.trim(status_name) do
      "" ->
        {:ok, fields}

      trimmed ->
        case resolve_status_id.(trimmed) do
          {:ok, status_id} -> {:ok, Map.put(fields, "status_id", status_id)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_put_status_id(fields, _status_name, _resolve_status_id), do: {:ok, fields}

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

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp redmine_tool_error_payload(:invalid_redmine_arguments) do
    %{
      "error" => %{
        "message" => "`redmine_update_issue` expects an object with issue_id and optional notes/status_name."
      }
    }
  end

  defp redmine_tool_error_payload(:missing_redmine_issue_id) do
    %{
      "error" => %{
        "message" => "`redmine_update_issue.issue_id` is required."
      }
    }
  end

  defp redmine_tool_error_payload(:missing_redmine_update_fields) do
    %{
      "error" => %{
        "message" => "`redmine_update_issue` requires notes or status_name."
      }
    }
  end

  defp redmine_tool_error_payload(:missing_redmine_url) do
    %{
      "error" => %{
        "message" => "Symphony is missing Redmine URL. Set `tracker.endpoint` in `WORKFLOW.md` or export `REDMINE_URL`."
      }
    }
  end

  defp redmine_tool_error_payload(:missing_redmine_api_key) do
    %{
      "error" => %{
        "message" => "Symphony is missing Redmine auth. Set `tracker.api_key` in `WORKFLOW.md` or export `REDMINE_API_KEY`."
      }
    }
  end

  defp redmine_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Redmine tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
