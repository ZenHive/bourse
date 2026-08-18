defmodule Mix.Tasks.Ccxt.RecordFixtures do
  @shortdoc "Capture scrubbed live response bodies for offline tier-1 replay"

  @moduledoc """
  Records one live response per `{venue, method}` into
  `test/fixtures/responses/<venue>/<method>.json`, or error recordings into
  `test/fixtures/recorded_errors/<venue>/<method>.json`.

  Re-run when exchange wire shapes drift. Fixtures are decoded JSON bodies only —
  no hand-curation. Fan-out methods (e.g. binance `fetch_markets`) store a
  `responses` array of `%{"api" => section, "body" => ...}` entries so the
  Compatibility tooling can replay every CCXT-JS section; single-endpoint methods keep
  the legacy top-level `"body"` shape. Error captures freeze the scrubbed raw
  error body plus HTTP status for oracle provenance.

  ## Scope

  Capture pairs come from `Bourse.RecordedResponseFixtures.capture_targets/0`.
  Account-scoped targets use their authored testnet/demo credential environment,
  except binance `fetch_trading_fees`, which records production `sapi` because
  the Spot Test Network has no `/sapi` host. Every body is scrubbed before it
  is written. Partial re-records merge into
  `_manifest.json` rather than replacing it.

  ## Usage

      mix ccxt.record_fixtures
      mix ccxt.record_fixtures --public
      mix ccxt.record_fixtures --private
      mix ccxt.record_fixtures --private deribit
      mix ccxt.record_fixtures --writes
      mix ccxt.record_fixtures --writes bybit
      mix ccxt.record_fixtures --errors
      mix ccxt.record_fixtures --errors bybit
      mix ccxt.record_fixtures bybit fetch_ticker
      mix ccxt.record_fixtures binance fetch_markets
      mix ccxt.record_fixtures binance error_bad_symbol

  With no filter, all read targets are recorded (public + private). Write and
  error categories are opt-in via `--writes` / `--errors`. Private and some error
  targets require the environment variables named in their capture profiles —
  missing credentials fail loudly with setup instructions.
  """

  use Mix.Task

  alias Bourse.JsonDocument
  alias Bourse.RecordedResponseFixtures
  alias Bourse.RecordedResponseFixtures.ListBody
  alias Bourse.RecordedResponseFixtures.RequestCongruence

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:bourse)

    {category_filter, exchange_filter, method_filter} = parse_args(args)
    targets = targets(category_filter, exchange_filter, method_filter)

    if targets == [] do
      raise Mix.Error, "No matching {venue, method} pairs for args: #{inspect(args)}"
    end

    roots =
      targets
      |> Enum.map(fn {exchange_id, method} -> fixture_root_for(exchange_id, method) end)
      |> Enum.uniq()

    Enum.each(roots, fn root ->
      Mix.shell().info("Recording into #{root}/")
    end)

    Mix.shell().info("Recording #{length(targets)} fixture(s)\n")

    results =
      Enum.map(targets, fn {exchange_id, method} ->
        path = RecordedResponseFixtures.fixture_path(exchange_id, method)
        root = fixture_root_for(exchange_id, method)

        case RecordedResponseFixtures.capture_fixture(exchange_id, method) do
          {:ok, fixture} ->
            File.mkdir_p!(Path.dirname(path))
            fixture = maybe_annotate_list_body(fixture, path, method)
            # Compact-encode: fetchMarkets captures are multi-MB; pretty-printing
            # bloated them ~2x (task 211). Per-venue rollouts (207-210) must not
            # each add tens of MB of whitespace.
            File.write!(path, Jason.encode!(fixture) <> "\n")
            Mix.shell().info("  wrote #{path}")
            {:ok, root, path, fixture}

          {:error, {:missing_credentials, missing, instructions}} ->
            Mix.shell().error("  FAILED #{exchange_id}/#{method}: missing credentials #{inspect(missing)}")
            Mix.shell().error("    #{instructions}")
            {:error, {exchange_id, method, {:missing_credentials, missing, instructions}}}

          {:error, reason} ->
            Mix.shell().error("  FAILED #{exchange_id}/#{method}: #{inspect(reason)}")
            {:error, {exchange_id, method, reason}}
        end
      end)

    failures = Enum.filter(results, &match?({:error, _}, &1))

    if failures != [] do
      raise Mix.Error,
            "#{length(failures)} fixture capture(s) failed — fix network/errors and re-run"
    end

    results
    |> Enum.group_by(fn {:ok, root, _path, _fixture} -> root end)
    |> Enum.each(fn {root, root_results} -> write_manifest!(root, root_results) end)

    Mix.shell().info("\nRecorded #{length(results)} fixture(s).")
  end

  defp fixture_root_for(exchange_id, method) do
    case RecordedResponseFixtures.capture_category(exchange_id, method) do
      :error -> RecordedResponseFixtures.error_fixture_root()
      _other -> RecordedResponseFixtures.fixture_root()
    end
  end

  defp write_manifest!(fixture_root, results) do
    newly_recorded =
      results
      |> Enum.filter(&match?({:ok, _, _, _}, &1))
      |> Map.new(fn {:ok, root, path, fixture} ->
        relative_path = Path.relative_to(path, root)
        {relative_path, manifest_recording(relative_path, fixture, root)}
      end)

    existing =
      fixture_root
      |> manifest_recordings()
      |> Map.new(&{&1["path"], &1})

    recordings =
      existing
      |> Map.merge(newly_recorded)
      |> Map.values()
      |> Enum.sort_by(& &1["path"])

    manifest =
      if error_root?(fixture_root) do
        %{
          "count" => length(recordings),
          "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "recordings" => recordings,
          "schema_version" => 1
        }
      else
        %{
          "count" => length(recordings),
          "fixtures" => Enum.map(recordings, & &1["path"]),
          "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "recordings" => recordings
        }
      end

    path = Path.join(fixture_root, "_manifest.json")
    File.write!(path, Jason.encode!(manifest, pretty: true) <> "\n")
  end

  defp error_root?(fixture_root) do
    String.contains?(fixture_root, "recorded_errors")
  end

  defp manifest_recordings(fixture_root) do
    path = Path.join(fixture_root, "_manifest.json")

    if File.exists?(path) do
      manifest = JsonDocument.decode_file!(path)

      case Map.get(manifest, "recordings") do
        recordings when is_list(recordings) -> recordings
        _ -> legacy_manifest_recordings(fixture_root, Map.get(manifest, "fixtures", []))
      end
    else
      []
    end
  end

  defp legacy_manifest_recordings(fixture_root, paths) do
    Enum.map(paths, fn relative_path ->
      fixture = fixture_root |> Path.join(relative_path) |> JsonDocument.decode_file!()
      manifest_recording(relative_path, fixture)
    end)
  end

  defp manifest_recording(relative_path, fixture, fixture_root \\ nil) do
    {exchange_id, method} = fixture_identity(relative_path, fixture)
    oracle = RecordedResponseFixtures.oracle_identity(exchange_id, method) || %{}
    captured_at = Map.get(fixture, "captured_at")

    %{
      "captured_at" => captured_at,
      "capture_date" => if(is_binary(captured_at), do: String.slice(captured_at, 0, 10)),
      "endpoint" => Map.get(fixture, "endpoint") || Map.get(oracle, "endpoint"),
      "host" => Map.get(fixture, "host") || Map.get(oracle, "host"),
      "method" => Atom.to_string(method),
      "path" => relative_path,
      "request_params_sha256" => RequestCongruence.request_params_sha256(fixture),
      "venue" => exchange_id
    }
    |> maybe_put_oracle_membership(fixture)
    |> maybe_put_error_fields(fixture, oracle, fixture_root)
    |> maybe_put_list_body(fixture, method)
  end

  defp maybe_put_error_fields(recording, fixture, oracle, fixture_root) do
    if error_root?(fixture_root || "") or Map.has_key?(fixture, "code") do
      recording
      |> Map.put("code", Map.get(fixture, "code"))
      |> Map.put("http_status", Map.get(fixture, "http_status"))
      |> Map.put("error_kind", Map.get(fixture, "error_kind") || Map.get(oracle, "error_kind"))
    else
      recording
    end
  end

  defp maybe_put_list_body(recording, fixture, method) do
    if ListBody.list_method?(method) do
      body_populated =
        case Map.fetch(fixture, "body_populated") do
          {:ok, value} when is_boolean(value) -> value
          _missing -> ListBody.body_populated?(Map.get(fixture, "body"))
        end

      Map.put(recording, "body_populated", body_populated)
    else
      recording
    end
  end

  defp maybe_put_oracle_membership(recording, %{"oracle_membership" => [_ | _] = membership}) do
    Map.put(recording, "oracle_membership", membership)
  end

  defp maybe_put_oracle_membership(recording, _fixture), do: recording

  defp maybe_annotate_list_body(fixture, path, method) do
    if ListBody.list_method?(method) do
      previous = if File.exists?(path), do: JsonDocument.decode_file!(path)
      ListBody.annotate(fixture, previous)
    else
      fixture
    end
  end

  defp fixture_identity(relative_path, fixture) do
    [exchange_id, filename] = Path.split(relative_path)
    method_name = Map.get(fixture, "method") || Path.rootname(filename)
    {Map.get(fixture, "exchange") || exchange_id, String.to_existing_atom(method_name)}
  end

  defp parse_args([]), do: {nil, nil, nil}
  defp parse_args(["--public"]), do: {:public, nil, nil}
  defp parse_args(["--private"]), do: {:private, nil, nil}
  defp parse_args(["--writes"]), do: {:write, nil, nil}
  defp parse_args(["--errors"]), do: {:error, nil, nil}
  defp parse_args(["--public", exchange_id]), do: {:public, exchange_id, nil}
  defp parse_args(["--private", exchange_id]), do: {:private, exchange_id, nil}
  defp parse_args(["--writes", exchange_id]), do: {:write, exchange_id, nil}
  defp parse_args(["--errors", exchange_id]), do: {:error, exchange_id, nil}

  defp parse_args([exchange_id]), do: {nil, exchange_id, nil}

  defp parse_args([exchange_id, method]) do
    method_atom =
      RecordedResponseFixtures.capture_targets()
      |> Enum.map(&elem(&1, 1))
      |> Enum.find(fn candidate -> Atom.to_string(candidate) == method end)

    {nil, exchange_id, method_atom || raise(Mix.Error, "unknown fixture capture method: #{method}")}
  end

  defp parse_args(_),
    do:
      raise(
        Mix.Error,
        "usage: mix ccxt.record_fixtures [--public [venue] | --private [venue] | --writes [venue] | --errors [venue] | venue [method]]"
      )

  defp targets(category_filter, exchange_filter, method_filter) do
    Enum.filter(RecordedResponseFixtures.capture_targets(), fn {exchange_id, method} ->
      match_category?(exchange_id, method, category_filter, method_filter) and
        match_exchange?(exchange_id, exchange_filter) and match_method?(method, method_filter)
    end)
  end

  # Default lane is success-path reads only. Writes and errors are opt-in via
  # flags, or via an explicit method name (e.g. `mix ccxt.record_fixtures bybit error_bad_symbol`).
  defp match_category?(_exchange_id, _method, nil, method_filter) when not is_nil(method_filter), do: true

  defp match_category?(exchange_id, method, nil, _method_filter) do
    RecordedResponseFixtures.capture_category(exchange_id, method) not in [:write, :error]
  end

  defp match_category?(exchange_id, method, filter, _method_filter),
    do: RecordedResponseFixtures.capture_category(exchange_id, method) == filter

  defp match_exchange?(_exchange_id, nil), do: true
  defp match_exchange?(exchange_id, filter), do: exchange_id == filter

  defp match_method?(_method, nil), do: true
  defp match_method?(method, filter), do: method == filter
end
