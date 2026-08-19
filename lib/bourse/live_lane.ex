defmodule Bourse.LiveLane do
  @moduledoc """
  Aggregates the scheduled live lane into one durable per-run artifact.

  Surfaces: online authority check, REST live-drift, the `:network` /
  `:capability_live` corpus (including WebSocket auth smoke), listen-key
  mutation probes, and the classified WebSocket first-frame matrix.
  """

  alias Bourse.LiveLane.FirstFrame
  alias Bourse.Spec
  alias Bourse.WS.Config

  @type exclusion :: %{
          required(:venue) => String.t(),
          required(:surface) => String.t(),
          required(:reason) => String.t(),
          required(:tracking) => String.t()
        }

  @type report :: %{
          required(:exclusions) => [exclusion()],
          required(:failures) => [map()],
          required(:run) => map(),
          required(:status) => String.t(),
          required(:surfaces) => map(),
          required(:venues) => [map()]
        }

  @corpus_include ~w(network capability_live integration)
  @corpus_exclude ~w(dangerous raw public_probe unified_integration invalid_creds symbol_public_probe)

  @corpus_files [
    "test/bourse/alpaca_authored_integration_test.exs",
    "test/bourse/binance_authored_integration_test.exs",
    "test/bourse/binance_contract_unit_integration_test.exs",
    "test/bourse/binance_query_array_integration_test.exs",
    "test/bourse/binancecoinm_promotion_integration_test.exs",
    "test/bourse/bybit_account_analytics_integration_test.exs",
    "test/bourse/bybit_authored_integration_test.exs",
    "test/bourse/coinbaseexchange_promotion_integration_test.exs",
    "test/bourse/deribit_authored_integration_test.exs",
    "test/bourse/derive_authored_integration_test.exs",
    "test/bourse/hyperliquid_authored_integration_test.exs",
    "test/bourse/lighter_promotion_integration_test.exs",
    "test/bourse/lighter_signing_integration_test.exs",
    "test/bourse/linear_contract_unit_integration_test.exs",
    "test/bourse/okx_authored_integration_test.exs",
    "test/bourse/okx_demo_integration_test.exs",
    "test/bourse/option_surface_integration_test.exs",
    "test/bourse/public_api_live_test.exs",
    "test/bourse/public_read_round_trip_integration_test.exs",
    "test/bourse/time_window_integration_test.exs",
    "test/bourse/unified/read_parse_slots_test.exs",
    "test/bourse/ws/auth_live_smoke_test.exs",
    "test/bourse/ws/binance_watch_frame_delivery_test.exs",
    "test/bourse/ws/binance_watch_order_book_broadcast_test.exs",
    "test/bourse/ws/canary_test.exs",
    "test/bourse/ws/subscribe_rejection_live_test.exs"
  ]

  @doc "ExUnit include tags the scheduled live corpus runs with."
  @spec corpus_include() :: [String.t()]
  def corpus_include, do: @corpus_include

  @doc "ExUnit exclude tags that keep generated probes and mutations out of the corpus."
  @spec corpus_exclude() :: [String.t()]
  def corpus_exclude, do: @corpus_exclude

  @doc "Authored `:network` / `:capability_live` files the corpus is expected to execute."
  @spec corpus_files() :: [String.t()]
  def corpus_files, do: @corpus_files

  @doc "Registered reasons for venues or surfaces the first-frame matrix does not probe."
  @spec exclusions() :: [exclusion()]
  def exclusions, do: FirstFrame.exclusions()

  @doc """
  Builds the durable lane artifact from per-surface reports.

  Each of `:drift`, `:corpus`, `:auth_smoke`, and `:ws` is already-decoded
  JSON (`{:ok, map()}` or `{:error, reason}`). Missing reports are failures:
  a later reader must be able to tell coverage from silence.
  """
  @spec aggregate(keyword()) :: {:ok, report()} | {:error, report()}
  def aggregate(opts) do
    drift = Keyword.get(opts, :drift, {:error, "report path missing"})
    corpus = Keyword.get(opts, :corpus, {:error, "report path missing"})
    auth_smoke = Keyword.get(opts, :auth_smoke, {:error, "report path missing"})
    ws = Keyword.get(opts, :ws, {:error, "report path missing"})
    authority_rc = Keyword.get(opts, :authority_rc, 1)

    surfaces = %{
      authority: authority_surface(authority_rc, Keyword.get(opts, :authority)),
      rest_drift: json_surface(drift, "live-drift-report.json"),
      live_corpus: corpus_surface(corpus),
      ws_auth_smoke_dangerous: json_surface(auth_smoke, "ws-auth-smoke-dangerous-report.json"),
      ws_first_frame: ws_surface(ws)
    }

    failures =
      surface_failures(surfaces) ++
        List.wrap(json_ok_get(ws, "failures", [])) ++
        List.wrap(json_ok_get(drift, "failures", []))

    venues = venue_rows(drift, ws)

    status =
      if failures == [] and Enum.all?(surfaces, fn {_name, surface} -> surface.status == "passed" end),
        do: "passed",
        else: "failed"

    report = %{
      exclusions: exclusions(),
      failures: failures,
      run: run_identity(),
      status: status,
      surfaces: surfaces,
      venues: venues
    }

    if status == "passed", do: {:ok, report}, else: {:error, report}
  end

  defp authority_surface(rc, path) when rc == 0 do
    %{report: path, status: "passed"}
  end

  defp authority_surface(rc, path) do
    %{report: path, status: "failed", reason: "authority_check exited #{rc}"}
  end

  defp json_surface({:ok, json}, default_name) do
    %{
      report: default_name,
      status: json["status"] || json_summary_status(json),
      summary: json["summary"]
    }
  end

  defp json_surface({:error, reason}, default_name) do
    %{report: default_name, status: "failed", reason: reason}
  end

  defp ws_surface({:ok, json}) do
    %{
      report: "ws-first-frame-report.json",
      status: json["status"] || "failed",
      venues: json["venues"] || []
    }
  end

  defp ws_surface({:error, reason}) do
    %{report: "ws-first-frame-report.json", status: "failed", reason: reason}
  end

  defp corpus_surface({:ok, json}) do
    summary = json["summary"] || %{}
    failures = corpus_failures(json)

    %{
      exclude: @corpus_exclude,
      failures: failures,
      files: @corpus_files,
      include: @corpus_include,
      report: "live-corpus-report.json",
      status: json_summary_status(json),
      summary: Map.take(summary, ["total", "passed", "failed", "excluded", "skipped", "result"])
    }
  end

  defp corpus_surface({:error, reason}) do
    %{
      exclude: @corpus_exclude,
      files: @corpus_files,
      include: @corpus_include,
      report: "live-corpus-report.json",
      status: "failed",
      reason: reason
    }
  end

  defp json_summary_status(%{"status" => status}) when is_binary(status), do: status

  defp json_summary_status(%{"summary" => %{"result" => "passed", "failed" => failed}}) when failed in [0, nil],
    do: "passed"

  defp json_summary_status(%{"summary" => %{"failed" => 0, "result" => result}}) when result in [nil, "passed"],
    do: "passed"

  defp json_summary_status(_json), do: "failed"

  defp corpus_failures(%{"tests" => tests}) when is_list(tests) do
    for %{"state" => "failed"} = test <- tests do
      %{file: test["file"], message: failure_message(test), name: test["name"]}
    end
  end

  defp corpus_failures(_json), do: []

  defp failure_message(%{"failures" => [%{"message" => message} | _]}) when is_binary(message), do: message
  defp failure_message(%{"message" => message}) when is_binary(message), do: message
  defp failure_message(_test), do: "failed"

  defp surface_failures(surfaces) do
    for {name, %{status: status} = surface} <- surfaces, status != "passed" do
      %{
        reason: Map.get(surface, :reason) || "#{name} #{status}",
        surface: Atom.to_string(name)
      }
    end
  end

  defp venue_rows(drift, ws) do
    drift_venues = json_ok_get(drift, "venues", [])
    ws_venues = json_ok_get(ws, "venues", [])
    exclusions = exclusions()

    Spec.exchanges()
    |> Enum.sort()
    |> Enum.map(fn venue ->
      %{
        rest: drift_row(venue, drift_venues),
        venue: venue,
        ws_private: ws_row(venue, "private", ws_venues, exclusions),
        ws_public: ws_row(venue, "public", ws_venues, exclusions)
      }
    end)
  end

  defp drift_row(venue, venues) do
    case Enum.find(venues, &(venue_id(&1) == venue)) do
      nil ->
        %{"status" => "missing", "reason" => "live-drift report did not name #{venue}"}

      row ->
        %{
          "private" => Map.get(row, "private") || Map.get(row, :private),
          "public" => Map.get(row, "public") || Map.get(row, :public)
        }
    end
  end

  defp ws_row(venue, section, venues, exclusions) do
    case Enum.find(venues, &(venue_id(&1) == venue and section_of(&1) == section)) do
      nil ->
        case Enum.find(exclusions, &(&1.venue == venue and &1.surface == "ws_#{section}")) do
          nil ->
            %{"status" => "missing", "reason" => "no first-frame probe or exclusion for #{venue} #{section}"}

          exclusion ->
            %{"status" => "excluded", "reason" => exclusion.reason, "tracking" => exclusion.tracking}
        end

      row ->
        stringify_ws_row(row)
    end
  end

  defp stringify_ws_row(row) when is_map(row) do
    Map.new(row, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp venue_id(%{venue: venue}), do: venue
  defp venue_id(%{"venue" => venue}), do: venue
  defp venue_id(_row), do: nil

  defp section_of(%{section: section}), do: to_string(section)
  defp section_of(%{"section" => section}), do: to_string(section)
  defp section_of(_row), do: "public"

  defp json_ok_get({:ok, json}, key, default), do: Map.get(json, key, default)
  defp json_ok_get(_other, _key, default), do: default

  defp run_identity do
    id = System.get_env("GITHUB_RUN_ID") || "local"
    server = System.get_env("GITHUB_SERVER_URL")
    repository = System.get_env("GITHUB_REPOSITORY")
    url = if server && repository && id != "local", do: "#{server}/#{repository}/actions/runs/#{id}"
    %{id: id, url: url, websocket_supported: Config.supported_exchanges()}
  end
end
