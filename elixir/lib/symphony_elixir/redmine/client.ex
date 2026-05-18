defmodule SymphonyElixir.Redmine.Client do
  @moduledoc """
  Thin Redmine REST client for polling issues and writing comments/status updates.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 100
  @max_pages 50

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- require_redmine_config(tracker),
         {:ok, issues} <- fetch_issue_pages(candidate_params(tracker)) do
      {:ok, filter_issues_by_states(issues, tracker.active_states)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker

    with :ok <- require_redmine_config(tracker),
         {:ok, issues} <- fetch_issue_pages(base_issue_params(tracker)) do
      {:ok, filter_issues_by_states(issues, state_names)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker

    with :ok <- require_redmine_config(tracker) do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
        case get_json("/issues/#{issue_id}.json", %{}) do
          {:ok, %{"issue" => issue}} -> {:cont, {:ok, [normalize_issue(issue) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, :redmine_unknown_payload}}
        end
      end)
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(Enum.reject(issues, &is_nil/1))}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec update_issue(String.t(), map()) :: :ok | {:error, term()}
  def update_issue(issue_id, fields) when is_binary(issue_id) and is_map(fields) do
    case put_json("/issues/#{issue_id}.json", %{"issue" => fields}) do
      {:ok, %{status: status}} when status in 200..204 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:redmine_api_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve_status_id(String.t()) :: {:ok, integer()} | {:error, term()}
  def resolve_status_id(state_name) when is_binary(state_name) do
    normalized = normalize_text(state_name)

    with {:ok, %{"issue_statuses" => statuses}} <- get_json("/issue_statuses.json", %{}) do
      statuses
      |> Enum.find(fn status -> normalize_text(status["name"]) == normalized end)
      |> case do
        %{"id" => status_id} when is_integer(status_id) -> {:ok, status_id}
        %{"id" => status_id} when is_binary(status_id) -> parse_int(status_id)
        _ -> {:error, :redmine_status_not_found}
      end
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue), do: normalize_issue(issue)

  @doc false
  @spec filter_issues_by_states_for_test([Issue.t()], [String.t()]) :: [Issue.t()]
  def filter_issues_by_states_for_test(issues, states), do: filter_issues_by_states(issues, states)

  defp require_redmine_config(tracker) do
    cond do
      not is_binary(tracker.endpoint) -> {:error, :missing_redmine_url}
      not is_binary(tracker.api_key) -> {:error, :missing_redmine_api_key}
      true -> :ok
    end
  end

  defp fetch_issue_pages(params) do
    do_fetch_issue_pages(params, 0, 0, [])
  end

  defp do_fetch_issue_pages(_params, _offset, page, acc) when page >= @max_pages do
    {:ok, Enum.reverse(acc)}
  end

  defp do_fetch_issue_pages(params, offset, page, acc) do
    params = Map.merge(params, %{"limit" => @page_size, "offset" => offset})

    case get_json("/issues.json", params) do
      {:ok, %{"issues" => issues} = body} when is_list(issues) ->
        normalized = issues |> Enum.map(&normalize_issue/1) |> Enum.reject(&is_nil/1)
        total = parse_total(body["total_count"])
        next_offset = offset + length(issues)

        if issues == [] or next_offset >= total do
          {:ok, Enum.reverse(normalized, acc)}
        else
          do_fetch_issue_pages(params, next_offset, page + 1, Enum.reverse(normalized, acc))
        end

      {:ok, _body} ->
        {:error, :redmine_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp candidate_params(tracker) do
    tracker
    |> base_issue_params()
    |> Map.put("status_id", "open")
    |> maybe_put_assignee(tracker.assignee)
    |> Map.put("sort", "updated_on:desc")
  end

  defp base_issue_params(tracker) do
    %{}
    |> maybe_put_project(tracker.project_slug)
  end

  defp maybe_put_project(params, project) when is_binary(project) and project != "",
    do: Map.put(params, "project_id", project)

  defp maybe_put_project(params, _project), do: params

  defp maybe_put_assignee(params, assignee) when is_binary(assignee) and assignee != "",
    do: Map.put(params, "assigned_to_id", assignee)

  defp maybe_put_assignee(params, _assignee), do: params

  defp get_json(path, params) do
    case Req.get(redmine_url(path),
           headers: redmine_headers(),
           params: params,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:redmine_api_status, status, body}}

      {:error, reason} ->
        Logger.error("Redmine request failed: #{inspect(reason)}")
        {:error, {:redmine_api_request, reason}}
    end
  end

  defp put_json(path, payload) do
    Req.put(redmine_url(path),
      headers: redmine_headers(),
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp redmine_url(path) do
    Config.settings!().tracker.endpoint <> path
  end

  defp redmine_headers do
    [{"X-Redmine-API-Key", Config.settings!().tracker.api_key}, {"Accept", "application/json"}]
  end

  defp normalize_issue(issue) when is_map(issue) do
    status = issue["status"] || %{}
    project = issue["project"] || %{}
    tracker = issue["tracker"] || %{}
    assignee = issue["assigned_to"] || %{}
    issue_id = issue["id"]

    %Issue{
      id: to_string(issue_id),
      identifier: "RM-#{issue_id}",
      title: issue["subject"],
      description: issue["description"],
      priority: get_in(issue, ["priority", "id"]),
      state: status["name"],
      branch_name: nil,
      url: Config.settings!().tracker.endpoint <> "/issues/#{issue_id}",
      assignee_id: assignee_id(assignee),
      labels: redmine_labels(project, tracker),
      assigned_to_worker: true,
      created_at: parse_redmine_datetime(issue["created_on"]),
      updated_at: parse_redmine_datetime(issue["updated_on"])
    }
  end

  defp normalize_issue(_issue), do: nil

  defp redmine_labels(project, tracker) do
    [
      "redmine",
      label_value(project["name"]),
      label_value(tracker["name"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp label_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(fn
      "" -> nil
      normalized -> normalized
    end)
  end

  defp label_value(_value), do: nil

  defp assignee_id(%{"id" => id}) when is_integer(id), do: to_string(id)
  defp assignee_id(%{"id" => id}) when is_binary(id), do: id
  defp assignee_id(_assignee), do: nil

  defp filter_issues_by_states(issues, state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_text/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    Enum.filter(issues, fn
      %Issue{state: state} -> MapSet.member?(normalized_states, normalize_text(state))
      _ -> false
    end)
  end

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()

  defp parse_redmine_datetime(nil), do: nil

  defp parse_redmine_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_total(total) when is_integer(total), do: total
  defp parse_total(total) when is_binary(total), do: String.to_integer(total)
  defp parse_total(_total), do: 0

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :redmine_invalid_status_id}
    end
  end
end
