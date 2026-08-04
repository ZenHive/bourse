defmodule Mix.Tasks.Ccxt.RecordAcceptedRequests.Bulk do
  @shortdoc "Capture provider-accepted public request branches"

  @moduledoc """
  Captures every authored public, non-transactional request branch.

      mix ccxt.record_accepted_requests.bulk
      mix ccxt.record_accepted_requests.bulk --pacing-ms 250
  """

  use Mix.Task

  alias Bourse.PublicAcceptedRequests

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:bourse)
    {opts, rest, invalid} = OptionParser.parse(args, strict: [pacing_ms: :integer])

    if rest != [] or invalid != [] or (opts[:pacing_ms] && opts[:pacing_ms] < 0) do
      Mix.raise("usage: mix ccxt.record_accepted_requests.bulk [--pacing-ms N]")
    end

    capture_opts = if opts[:pacing_ms], do: [pacing_ms: opts[:pacing_ms]], else: []

    results =
      Enum.flat_map(Bourse.Spec.exchanges(), fn venue ->
        Mix.shell().info("Capturing authored public request branches for #{venue}...")
        PublicAcceptedRequests.record_venue(venue, capture_opts)
      end)

    write_results!(results)
    report(results)
  end

  defp write_results!(results) do
    root = PublicAcceptedRequests.fixture_root()

    Enum.each(results, fn
      {:golden, golden} ->
        path = Path.join(root, PublicAcceptedRequests.fixture_relative_path(golden))
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Jason.encode!(golden, pretty: true) <> "\n")

      {:exclusion, _exclusion} ->
        :ok
    end)

    manifest = PublicAcceptedRequests.manifest(results)
    prune_orphaned_goldens!(root, manifest)
    File.mkdir_p!(root)
    File.write!(PublicAcceptedRequests.manifest_path(), Jason.encode!(manifest, pretty: true) <> "\n")
    PublicAcceptedRequests.validate_manifest!(manifest, root)
  end

  defp prune_orphaned_goldens!(root, manifest) do
    declared = MapSet.new(manifest["goldens"], & &1["path"])

    root
    |> Path.join("**/*.json")
    |> Path.wildcard()
    |> Enum.reject(
      &(Path.basename(&1) == "_manifest.json" or
          MapSet.member?(declared, Path.relative_to(&1, root)))
    )
    |> Enum.each(&File.rm!/1)
  end

  defp report(results) do
    accepted = Enum.count(results, &match?({:golden, _}, &1))
    excluded = Enum.count(results, &match?({:exclusion, _}, &1))
    Mix.shell().info("Recorded #{accepted} public accepted-request golden(s); #{excluded} dated exclusion(s).")
  end
end
