defmodule Bourse.LiveDrift do
  @moduledoc """
  Scheduled, read-only verification of provider response contracts.

  Public responses are compared with committed reality recordings only at
  envelope and field paths consumed by the authored runtime spec. Credentialed
  venues also prove one authenticated read; public-only venues declare that leg
  not applicable.

  A runner environment may declare venues it cannot reach (geo-blocked hosts)
  via the `LIVE_DRIFT_UNREACHABLE_OK` env var or the `:unreachable_ok` option.
  For those venues only, `$request` capture errors classified as
  `exchange_not_available` or `network_error` land in the report's
  `unreachable` section instead of `failures` — reported loudly, never graded
  green as evidence. Drift comparisons on a reachable response always fail hard
  regardless of the allowlist.
  """

  alias Bourse.LiveDrift.Comparator
  alias Bourse.LiveDrift.Failure
  alias Bourse.RecordedResponseFixtures
  alias Bourse.Spec

  @profiles %{
    "alpaca" => %{public: {:fetch_ticker, "ticker", "fetchTicker"}, private: :fetch_balance},
    "binance" => %{public: {:fetch_ohlcv, "ohlcv", "fetchOHLCV"}, private: :fetch_balance},
    "binancecoinm" => %{public: {:fetch_ticker, "ticker", "fetchTicker"}, private: :fetch_balance},
    "binanceusdm" => %{public: {:fetch_ohlcv, "ohlcv", "fetchOHLCV"}, private: :fetch_balance},
    "bybit" => %{public: {:fetch_ticker, "ticker", "fetchTicker"}, private: :fetch_balance},
    "coinbaseexchange" => %{public: {:fetch_ohlcv, "ohlcv", "fetchOHLCV"}, private: nil},
    "deribit" => %{public: {:fetch_ticker, "ticker", "fetchTicker"}, private: :fetch_balance},
    "derive" => %{public: {:fetch_trades, "trade", "fetchTrades"}, private: :fetch_balance},
    "hyperliquid" => %{public: {:fetch_ohlcv, "ohlcv", "fetchOHLCV"}, private: :fetch_balance},
    "lighter" => %{public: {:fetch_ticker, "ticker", "fetchTicker"}, private: :fetch_closed_orders},
    "okx" => %{public: {:fetch_ticker, "ticker", "fetchTicker"}, private: :fetch_balance}
  }

  @reachability_kinds ["exchange_not_available", "network_error"]

  @type report :: %{
          required(:failures) => [map()],
          required(:observations) => [map()],
          required(:run) => map(),
          required(:status) => String.t(),
          required(:unreachable) => [map()],
          required(:venues) => [map()]
        }
  @type option ::
          {:capture, (String.t(), atom(), keyword() -> {:ok, map()} | {:error, term()})}
          | {:capture_opts, keyword()}
          | {:get_env, (String.t() -> String.t() | nil)}
          | {:manifest_venues, [String.t()]}
          | {:unreachable_ok, [String.t()]}

  @doc "Returns the activated scheduled profile for every supported venue."
  @spec profiles() :: %{required(String.t()) => map()}
  def profiles, do: @profiles

  @doc "Validates exact support, read-only profiles, and all credentials."
  @spec preflight([option()]) :: :ok | {:error, term()}
  def preflight(opts \\ []) do
    manifest = Keyword.get(opts, :manifest_venues, Spec.exchanges())

    with :ok <- exact_support(manifest),
         :ok <- read_only_profiles() do
      credentials_present(Keyword.get(opts, :get_env, &System.get_env/1))
    end
  end

  @doc "Runs every public read and each applicable private read, returning a scrubbed report."
  @spec run([option()]) :: {:ok, report()} | {:error, report() | term()}
  def run(opts \\ []) do
    case preflight(opts) do
      :ok ->
        capture = Keyword.get(opts, :capture, &RecordedResponseFixtures.capture_fixture/3)
        capture_opts = Keyword.get(opts, :capture_opts, [])
        unreachable_ok = Keyword.get_lazy(opts, :unreachable_ok, &unreachable_ok_from_env/0)

        @profiles
        |> Enum.sort()
        |> Enum.reduce(base_report(), &verify_venue(&1, &2, capture, capture_opts, unreachable_ok))
        |> finish()

      {:error, reason} ->
        {:error, preflight_report(reason)}
    end
  end

  defp exact_support(manifest) do
    configured = Map.keys(@profiles)
    missing = configured -- manifest
    extra = manifest -- configured

    if missing == [] and extra == [] and length(manifest) == map_size(@profiles) do
      :ok
    else
      {:error, {:support_manifest_mismatch, %{actual: manifest, expected: configured, missing: missing, extra: extra}}}
    end
  end

  defp read_only_profiles do
    Enum.reduce_while(@profiles, :ok, fn {venue, profile}, :ok ->
      {public_method, _parse_type, _js_method} = profile.public

      case {RecordedResponseFixtures.capture_category(venue, public_method),
            private_capture_category(venue, profile.private)} do
        {:public, :private} -> {:cont, :ok}
        {:public, :not_applicable} -> {:cont, :ok}
        categories -> {:halt, {:error, {:unsafe_live_profile, venue, categories}}}
      end
    end)
  end

  defp private_capture_category(_venue, nil), do: :not_applicable
  defp private_capture_category(venue, method), do: RecordedResponseFixtures.capture_category(venue, method)

  defp credentials_present(get_env) do
    missing =
      for {venue, profile} <- @profiles,
          variable <- credential_variables(venue, profile),
          get_env.(variable) in [nil, ""],
          do: {venue, variable}

    if missing == [], do: :ok, else: {:error, {:missing_credentials, missing, setup_instructions(missing)}}
  end

  defp credential_variables(venue, profile) do
    {public_method, _parse_type, _js_method} = profile.public

    [public_method | List.wrap(profile.private)]
    |> Enum.flat_map(&RecordedResponseFixtures.required_credentials(venue, &1))
    |> Enum.uniq()
  end

  defp setup_instructions(missing) do
    exports =
      missing
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join("\n", &~s(export #{&1}="replace-me"))

    "Missing live drift credentials:\n#{exports}\nSee CLAUDE.md Testnet Credentials for provider setup."
  end

  defp verify_venue({venue, profile}, report, capture, capture_opts, unreachable_ok) do
    {method, parse_type, js_method} = profile.public

    {report, public_status} =
      case capture.(venue, method, capture_opts) do
        {:ok, live_public} ->
          baseline = load_baseline(venue, method)
          comparison = Comparator.compare(venue, method, parse_type, js_method, baseline, live_public)

          report =
            report
            |> Map.update!(:failures, &(comparison.failures ++ &1))
            |> Map.update!(:observations, &(comparison.observations ++ &1))

          status = if comparison.failures == [], do: "passed", else: "drift"
          {report, status}

        {:error, reason} ->
          record_capture_error(report, venue, method, reason, unreachable_ok)
      end

    {report, private_status} = verify_private(venue, profile.private, report, capture, capture_opts, unreachable_ok)

    venue_result = %{
      private: %{method: profile.private, status: private_status},
      public: %{method: method, status: public_status},
      venue: venue
    }

    Map.update!(report, :venues, &[venue_result | &1])
  end

  defp verify_private(_venue, nil, report, _capture, _capture_opts, _unreachable_ok), do: {report, "not_applicable"}

  defp verify_private(venue, method, report, capture, capture_opts, unreachable_ok) do
    case capture.(venue, method, capture_opts) do
      {:ok, _private} ->
        {report, "passed"}

      {:error, reason} ->
        record_capture_error(report, venue, method, reason, unreachable_ok)
    end
  end

  defp load_baseline(venue, method) do
    venue
    |> RecordedResponseFixtures.fixture_path(method)
    |> RecordedResponseFixtures.load_fixture!()
  end

  defp record_capture_error(report, venue, method, reason, unreachable_ok) do
    failure = capture_failure(venue, method, reason)

    if venue in unreachable_ok and failure.actual_type in @reachability_kinds do
      {Map.update!(report, :unreachable, &[failure | &1]), "unreachable"}
    else
      {Map.update!(report, :failures, &[failure | &1]), "failed"}
    end
  end

  defp unreachable_ok_from_env do
    "LIVE_DRIFT_UNREACHABLE_OK"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp capture_failure(venue, method, reason) do
    repair = Comparator.repair_paths(venue, method)

    Failure.new(
      venue,
      method,
      "$request",
      "successful_response",
      capture_error_kind(reason),
      repair.recapture,
      repair.reauthor
    )
  end

  defp preflight_report({:missing_credentials, missing, instructions}) do
    failures =
      Enum.map(missing, fn {venue, variable} ->
        Failure.new(
          venue,
          "preflight",
          "credentials.#{variable}",
          "configured_secret",
          "missing",
          instructions,
          "CLAUDE.md#testnet-credentials"
        )
      end)

    base_report() |> Map.put(:failures, failures) |> finish_error()
  end

  defp preflight_report({:support_manifest_mismatch, difference}) do
    base_report()
    |> Map.put(:failures, [
      Failure.new(
        "support_manifest",
        "preflight",
        "runtime_support.venues",
        "exact_runtime_support_manifest",
        inspect(difference),
        "priv/specs/json/runtime_support.json",
        "lib/bourse/live_drift.ex"
      )
    ])
    |> finish_error()
  end

  defp preflight_report({:unsafe_live_profile, venue, categories}) do
    base_report()
    |> Map.put(:failures, [
      Failure.new(
        venue,
        "preflight",
        "scheduled_profile.category",
        "{:public, :private_or_not_applicable}",
        inspect(categories),
        "lib/bourse/recorded_response_fixtures/capture.ex",
        "lib/bourse/live_drift.ex"
      )
    ])
    |> finish_error()
  end

  defp capture_error_kind(%Bourse.Error{type: type}), do: Atom.to_string(type)
  defp capture_error_kind({type, _detail}) when is_atom(type), do: Atom.to_string(type)
  defp capture_error_kind(type) when is_atom(type), do: Atom.to_string(type)
  defp capture_error_kind(_reason), do: "capture_error"

  defp base_report do
    %{
      failures: [],
      observations: [],
      run: run_identity(),
      status: "pending",
      unreachable: [],
      venues: []
    }
  end

  defp run_identity do
    id = System.get_env("GITHUB_RUN_ID") || "local"
    server = System.get_env("GITHUB_SERVER_URL")
    repository = System.get_env("GITHUB_REPOSITORY")
    url = if server && repository && id != "local", do: "#{server}/#{repository}/actions/runs/#{id}"
    %{id: id, url: url}
  end

  defp finish(report) do
    report = %{
      report
      | failures: Enum.reverse(report.failures),
        observations: Enum.reverse(report.observations),
        status: if(report.failures == [], do: "passed", else: "failed"),
        unreachable: Enum.reverse(report.unreachable),
        venues: Enum.reverse(report.venues)
    }

    if report.failures == [], do: {:ok, report}, else: {:error, report}
  end

  defp finish_error(report) do
    %{report | status: "failed", failures: Enum.reverse(report.failures)}
  end
end
