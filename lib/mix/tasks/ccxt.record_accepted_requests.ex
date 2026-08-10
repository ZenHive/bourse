defmodule Mix.Tasks.Ccxt.RecordAcceptedRequests do
  @shortdoc "Freeze fixture-signed requests proven by live exchange acceptance"

  @moduledoc """
  Records deterministic request goldens for the ten first-class venues.

  Each live request must receive HTTP 2xx plus venue-level business success.
  Live credentials and signatures remain in memory; only the equivalent request
  rebuilt with committed fixture credentials is written.

      mix ccxt.record_accepted_requests
      mix ccxt.record_accepted_requests deribit
  """

  use Mix.Task

  alias Bourse.ExchangeAcceptanceFixtures
  alias Bourse.JsonDocument

  @schema_version 1

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:bourse)

    venues = venues!(args)
    goldens = Enum.flat_map(venues, &record!/1)

    Enum.each(goldens, &write_golden!/1)
    write_manifest!()

    Mix.shell().info("Recorded #{length(goldens)} exchange-accepted request golden(s).")
  end

  defp venues!([]), do: ExchangeAcceptanceFixtures.first_class_venues()

  defp venues!([venue]) do
    if venue in ExchangeAcceptanceFixtures.first_class_venues() do
      [venue]
    else
      raise Mix.Error, "unknown first-class venue: #{venue}"
    end
  end

  defp venues!(_args) do
    raise Mix.Error, "usage: mix ccxt.record_accepted_requests [venue]"
  end

  defp record!(venue) do
    Mix.shell().info("Proving live exchange acceptance for #{venue}...")

    case ExchangeAcceptanceFixtures.record_all(venue) do
      {:ok, goldens} -> goldens
      {:error, reason} -> raise Mix.Error, "#{venue} acceptance capture failed: #{inspect(reason)}"
    end
  end

  defp write_golden!(%{"acceptance" => %{"venue" => venue, "method" => method} = acceptance} = golden) do
    profile_name = acceptance["profile"] || method

    {_venue, profile_id, _method_atom} =
      Enum.find(ExchangeAcceptanceFixtures.profiles(), fn {candidate_venue, candidate_profile, candidate_method} ->
        candidate_venue == venue and Atom.to_string(candidate_profile) == profile_name and
          Atom.to_string(candidate_method) == method
      end)

    path = ExchangeAcceptanceFixtures.fixture_path(venue, profile_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(golden, pretty: true) <> "\n")
    Mix.shell().info("  wrote #{path}")
  end

  defp write_manifest! do
    root = ExchangeAcceptanceFixtures.fixture_root()

    goldens =
      root
      |> Path.join("*/*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn path -> manifest_row(root, path, JsonDocument.decode_file!(path)) end)

    manifest = %{
      "count" => length(goldens),
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "goldens" => goldens,
      "oracle" => "exchange_acceptance",
      "schema_version" => @schema_version
    }

    File.write!(ExchangeAcceptanceFixtures.manifest_path(), Jason.encode!(manifest, pretty: true) <> "\n")
  end

  defp manifest_row(root, path, golden) do
    golden
    |> Map.fetch!("acceptance")
    |> Map.take([
      "business_success",
      "capture_date",
      "captured_at",
      "endpoint",
      "host",
      "http_status",
      "method",
      "profile",
      "venue"
    ])
    |> Map.put("label", Map.fetch!(golden, "label"))
    |> Map.put("path", Path.relative_to(path, root))
  end
end
