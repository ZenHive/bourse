defmodule Bourse.LiveLane.Ledger do
  @moduledoc """
  Classifies live-suite reds from `docs/prod-verification-ledger.md`.

  The JSON fence in that file is the only classification list. Tests must not
  keep a parallel roster of okx 50038 methods or state-dependent branches.
  """

  alias Bourse.Error

  @begin_marker "<!-- live-suite-classification:begin -->"
  @end_marker "<!-- live-suite-classification:end -->"
  # Needles must appear ONLY in the scenario's empty-state flunks. "empty account
  # state" and "empty collection" are deliberately absent: the shape/carve
  # mismatch message ends "...not empty account state", so either needle would
  # ledger a genuine carve defect as state-dependent.
  @empty_message_needles [
    "provider account state",
    "did not exercise",
    "no id from",
    "provider returned no rows"
  ]

  defmodule ErrorConfirmed do
    @moduledoc false
    defexception [:entry, :contract_id]

    @impl Exception
    def message(%__MODULE__{entry: entry, contract_id: id}) do
      "ledgered #{entry["class"]}: #{id} — #{entry["summary"]}"
    end
  end

  @doc "Loads the classification document from the ledger markdown file."
  @spec load!() :: map()
  def load! do
    contents = File.read!("docs/prod-verification-ledger.md")
    decode_document!(contents, "docs/prod-verification-ledger.md")
  end

  @doc "Path the suite writes ledgered hits to for the REST-read mix task."
  @spec hits_path() :: String.t()
  def hits_path, do: hits_path(File.cwd!())

  @doc """
  Hits path scoped to a checkout root.

  Several worktrees of this repo run their lanes concurrently on one host, so a
  single shared `/tmp` name would let one run's hits be read as another's and
  report a classification the lane never produced.
  """
  @spec hits_path(String.t()) :: String.t()
  def hits_path(root) when is_binary(root) do
    scope = :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    Path.join(System.tmp_dir!(), "bourse-ledger-hits-#{scope}.json")
  end

  @doc "Classifies one observed live outcome against the ledger document."
  @spec classify(map(), term(), map() | nil) :: {:ledgered, map()} | :genuine
  def classify(contract_case, observed, document \\ nil) do
    document = document || load!()
    venue = contract_case["venue"]
    method = contract_case["method"]

    document
    |> Map.fetch!("cases")
    |> Enum.filter(&covers?(&1, venue, method))
    |> Enum.find_value(:genuine, fn entry ->
      if match_observed?(entry, observed), do: {:ledgered, entry}
    end)
  end

  @doc "Raises `ErrorConfirmed` so the scenario can record a ledgered outcome as a pass."
  @spec confirm!(map(), map()) :: no_return()
  def confirm!(entry, contract_case) do
    raise ErrorConfirmed, entry: entry, contract_id: contract_case["id"]
  end

  @doc "Starts the per-suite hits collector. No-ops if it is already running."
  @spec start_hits!() :: :ok
  def start_hits! do
    case Process.whereis(__MODULE__.Hits) do
      nil ->
        {:ok, _pid} = Agent.start_link(fn -> [] end, name: __MODULE__.Hits)
        :ok

      _pid ->
        :ok
    end
  end

  @doc "Records a ledgered confirmation for the suite summary."
  @spec record(ErrorConfirmed.t() | map()) :: :ok
  def record(%ErrorConfirmed{} = confirmed) do
    record(%{
      "id" => confirmed.contract_id,
      "class" => confirmed.entry["class"],
      "summary" => confirmed.entry["summary"]
    })
  end

  def record(hit) when is_map(hit) do
    case Process.whereis(__MODULE__.Hits) do
      nil ->
        :ok

      _pid ->
        Agent.update(__MODULE__.Hits, &[hit | &1])
        :ok
    end
  end

  @doc "Returns recorded ledgered hits, newest last."
  @spec hits() :: [map()]
  def hits do
    case Process.whereis(__MODULE__.Hits) do
      nil -> []
      _pid -> __MODULE__.Hits |> Agent.get(& &1) |> Enum.reverse()
    end
  end

  @doc "Writes the hits file and prints the classified suite summary to stderr."
  @spec print_suite_summary(map()) :: :ok
  def print_suite_summary(result) when is_map(result) do
    recorded = hits()
    persist_hits!(recorded)
    genuine = Map.get(result, :failures) || Map.get(result, "failures") || 0
    IO.puts(:stderr, format_summary(recorded, genuine))
    :ok
  end

  @doc "Formats ledgered hits and genuine-failure count for a human reader."
  @spec format_summary([map()], non_neg_integer()) :: String.t()
  def format_summary(recorded, genuine) when is_list(recorded) and is_integer(genuine) do
    grouped = Enum.group_by(recorded, & &1["class"])

    lines =
      [
        "Live-suite classification (from docs/prod-verification-ledger.md):",
        class_line(grouped, "ledgered_demo_unavailable", "ledgered demo-unavailable"),
        class_line(grouped, "ledgered_state_dependent", "ledgered state-dependent"),
        class_line(grouped, "ledgered_unreachable", "ledgered unreachable"),
        "  genuine failures: #{genuine}"
      ]

    detail_lines =
      recorded
      |> Enum.sort_by(& &1["id"])
      |> Enum.map(fn hit ->
        "    #{hit["id"]} [#{hit["class"]}] #{hit["summary"]}"
      end)

    Enum.join(lines ++ detail_lines, "\n")
  end

  @doc "Classifies ExUnit JSON failure rows against the ledger document."
  @spec classify_report_failures([map()], map()) :: %{ledgered: [map()], genuine: [map()]}
  def classify_report_failures(tests, document) when is_list(tests) do
    Enum.reduce(tests, %{ledgered: [], genuine: []}, fn test, acc ->
      case classify_failure_row(test, document) do
        {:ledgered, entry} ->
          hit = %{"id" => test["name"], "class" => entry["class"], "summary" => entry["summary"]}
          %{acc | ledgered: [hit | acc.ledgered]}

        :genuine ->
          %{acc | genuine: [test | acc.genuine]}
      end
    end)
  end

  defp classify_failure_row(test, document) do
    message = failure_message(test)
    venue_method = venue_method_from_name(test["name"] || "")

    document
    |> Map.fetch!("cases")
    |> Enum.find_value(:genuine, fn entry ->
      if row_matches?(entry, venue_method, message), do: {:ledgered, entry}
    end)
  end

  defp row_matches?(entry, {venue, method}, message) do
    covers?(entry, venue, method) and message_matches?(entry, message)
  end

  defp row_matches?(_entry, :unknown, _message), do: false

  defp covers?(entry, venue, method) do
    entry["venue"] == venue and method in List.wrap(entry["methods"])
  end

  defp match_observed?(entry, {:error, %Error{} = error}) do
    match = entry["match"] || %{}

    error_selector?(match) and codes_match?(match["code"], error.code) and
      message_contains?(match, error.message)
  end

  defp match_observed?(entry, {:empty_resource, _source}), do: empty_match?(entry)
  defp match_observed?(entry, :empty_payload), do: empty_match?(entry)
  defp match_observed?(entry, :empty_collection), do: empty_match?(entry)
  defp match_observed?(_entry, _observed), do: false

  defp empty_match?(entry) do
    match = entry["match"] || %{}
    match["empty_resource"] == true or match["empty_payload"] == true or match["empty_collection"] == true
  end

  # An empty-resource / empty-payload row must not swallow an unrelated provider
  # error: `code` and `message_contains` absent used to wildcard-match every Error.
  defp error_selector?(match) do
    is_binary(match["code"]) or is_binary(match["message_contains"])
  end

  defp codes_match?(nil, _code), do: true
  defp codes_match?(expected, actual), do: to_string(expected) == to_string(actual)

  defp message_contains?(%{"message_contains" => needle}, message) when is_binary(needle) do
    is_binary(message) and String.contains?(message, needle)
  end

  defp message_contains?(_match, _message), do: true

  defp message_matches?(entry, message) when is_binary(message) do
    match = entry["match"] || %{}

    cond do
      is_binary(match["code"]) and String.contains?(message, to_string(match["code"])) ->
        message_contains?(match, message)

      empty_match?(entry) ->
        Enum.any?(@empty_message_needles, &String.contains?(message, &1))

      true ->
        message_contains?(match, message)
    end
  end

  defp message_matches?(_entry, _message), do: false

  defp failure_message(%{"message" => message}) when is_binary(message), do: message

  defp failure_message(%{"failures" => [failure | _]}) when is_map(failure) do
    failure["message"] || ""
  end

  defp failure_message(_test), do: ""

  defp venue_method_from_name(name) do
    trimmed = String.replace_prefix(name, "test ", "")

    case String.split(trimmed, ":", parts: 3) do
      [venue, method | _rest] when venue != "" and method != "" -> {venue, method}
      _other -> :unknown
    end
  end

  defp class_line(grouped, class, label) do
    "  #{label}: #{length(Map.get(grouped, class, []))}"
  end

  defp persist_hits!(recorded) do
    File.write!(hits_path(), Jason.encode!(recorded))
  end

  defp decode_document!(contents, path) do
    case extract_json(contents) do
      {:ok, json} ->
        document = Jason.decode!(json)
        validate_document!(document, path)
        document

      :error ->
        raise ArgumentError,
              "#{path} is missing the #{@begin_marker} JSON fence; live-suite classification cannot run"
    end
  end

  defp extract_json(contents) do
    with {start_index, start_len} <- :binary.match(contents, @begin_marker),
         rest = binary_part(contents, start_index + start_len, byte_size(contents) - start_index - start_len),
         {end_index, _end_len} <- :binary.match(rest, @end_marker) do
      json = rest |> binary_part(0, end_index) |> String.trim() |> unwrap_fence()
      {:ok, json}
    else
      :nomatch -> :error
    end
  end

  defp unwrap_fence(text) do
    trimmed = String.trim(text)

    case String.split(trimmed, "\n", parts: 2) do
      ["```json", body] ->
        body
        |> String.trim()
        |> String.trim_trailing("```")
        |> String.trim()

      _other ->
        trimmed
    end
  end

  defp validate_document!(document, path) do
    if !(is_map(document) and is_list(document["cases"]) and document["schema_version"] == 1) do
      raise ArgumentError, "#{path} live-suite classification JSON must be schema_version 1 with a cases list"
    end

    Enum.each(document["cases"], fn entry ->
      if !(is_binary(entry["id"]) and is_binary(entry["class"]) and is_binary(entry["venue"]) and
             is_list(entry["methods"]) and is_binary(entry["summary"])) do
        raise ArgumentError, "#{path} classification case #{inspect(entry["id"])} is missing required fields"
      end
    end)
  end
end
