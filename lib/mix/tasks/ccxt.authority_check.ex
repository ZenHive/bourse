defmodule Mix.Tasks.Ccxt.AuthorityCheck do
  @shortdoc "Validates venue authority provenance and optionally checks upstream drift"

  @moduledoc """
  Validates the first-class venue authority manifests without network access.

      mix ccxt.authority_check

  Opt into a live upstream drift check, or materialize the pinned reference-only
  artifacts outside `priv/authority/` for inspection:

      mix ccxt.authority_check --online
      mix ccxt.authority_check --fetch /tmp/ccxt-authority

  The default command is offline. `--online` and `--fetch` are explicit network
  operations and are not part of the offline test suite.
  """

  use Mix.Task

  alias Mix.Tasks.Ccxt.AuthorityCorpus

  @default_root "priv/authority"
  @curl_timeout_seconds 120
  @drift_acknowledgement_days 30
  @switches [online: :boolean, fetch: :string, root: :string]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)
    ensure_no_positional!(positional)
    ensure_mode!(opts)

    root = Keyword.get(opts, :root, @default_root)
    manifests = AuthorityCorpus.load!(root)
    execute!(manifests, root, opts)
  end

  @doc """
  Checks every manifest's mutable upstream for drift and its pinned bytes for corruption.

  Typed contract drift raises. Prose/docs drift warns only when the manifest
  carries a current `drift_detected` acknowledgment; missing or stale
  acknowledgments raise. A pinned fetch target mismatch remains a corpus
  verification error. `opts` accepts `:fetcher`, `:git_head`, and `:today`
  overrides for offline tests.
  """
  @spec check_upstream!([map()], keyword()) :: :ok
  def check_upstream!(manifests, opts \\ []) do
    fetcher = Keyword.get(opts, :fetcher, &curl!/1)
    git_head = Keyword.get(opts, :git_head, &git_head!/1)
    today = Keyword.get(opts, :today, Date.utc_today())
    Enum.each(manifests, &check_manifest!(&1, fetcher, git_head, today))
    Mix.shell().info("Authority upstream check passed for #{length(manifests)} venues.")
    :ok
  end

  @doc """
  Raises unless `destination` resolves outside the authority tree at `root`.

  Materializing pinned bytes inside `priv/authority/` would turn the read-only
  provenance tree into a content store, so the destination must be a sibling or
  unrelated directory.
  """
  @spec ensure_external_destination!(Path.t(), Path.t()) :: :ok
  def ensure_external_destination!(destination, root) do
    destination = Path.expand(destination)
    root = Path.expand(root)

    if destination == root or String.starts_with?(destination, root <> "/") do
      Mix.raise("--fetch destination must be outside #{root}")
    end

    :ok
  end

  @doc "Fetches pinned artifacts to a caller-selected directory after verifying hashes."
  @spec fetch!([map()], Path.t(), Path.t()) :: :ok
  def fetch!(manifests, destination, root) do
    ensure_external_destination!(destination, root)
    Enum.each(manifests, &fetch_manifest!(&1, destination))
    Mix.shell().info("Fetched pinned authority artifacts to #{Path.expand(destination)}.")
    :ok
  end

  defp execute!(manifests, root, opts) do
    cond do
      destination = opts[:fetch] -> fetch!(manifests, destination, root)
      opts[:online] -> check_upstream!(manifests)
      true -> offline_success(manifests, root)
    end
  end

  defp offline_success(manifests, root) do
    Mix.shell().info("Authority corpus passed offline validation: #{length(manifests)} venues under #{root}.")
    :ok
  end

  defp check_manifest!(manifest, fetcher, git_head, today) do
    Enum.each(manifest["artifacts"], fn artifact ->
      drift = detect_drift(artifact, fetcher, git_head)
      handle_drift!(drift, manifest["venue"], artifact, today)
      verify_pinned_fetch!(artifact, fetcher)

      if drift == :unchanged do
        Mix.shell().info("#{manifest["venue"]}/#{artifact["id"]}: upstream unchanged")
      end
    end)
  end

  # When the pinned fetch target is also the mutable drift target, the drift
  # check above already graded those exact bytes — re-fetching would compare a
  # hash against itself. A separate pinned target is immutable by construction,
  # so a mismatch there is a corrupted fetch, not drift.
  defp verify_pinned_fetch!(artifact, fetcher) do
    if artifact["fetch_url"] != get_in(artifact, ["drift", "url"]) do
      AuthorityCorpus.verify_content!(artifact, fetcher.(artifact["fetch_url"]), artifact["id"])
    end

    :ok
  end

  defp fetch_manifest!(manifest, destination) do
    Enum.each(manifest["artifacts"], fn artifact ->
      contents = fetch_and_verify!(artifact)
      output_path = Path.join([destination, manifest["venue"], artifact["filename"]])
      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, contents)
    end)
  end

  defp fetch_and_verify!(artifact) do
    contents = curl!(artifact["fetch_url"])
    AuthorityCorpus.verify_content!(artifact, contents, artifact["id"])
    contents
  end

  defp detect_drift(%{"drift" => %{"mode" => "sha256", "url" => url}} = artifact, fetcher, _git_head) do
    expected = artifact["sha256"]
    actual = AuthorityCorpus.sha256(fetcher.(url))
    if actual == expected, do: :unchanged, else: {:drift, url, expected, actual}
  end

  defp detect_drift(%{"drift" => %{"mode" => "git_head", "repository_url" => url}} = artifact, _fetcher, git_head) do
    expected = artifact["upstream_pin"]["value"]
    actual = git_head.(url)
    if actual == expected, do: :unchanged, else: {:drift, url, expected, actual}
  end

  defp handle_drift!(:unchanged, _venue, _artifact, _today), do: :ok

  defp handle_drift!({:drift, target, expected, actual}, venue, artifact, today) do
    case AuthorityCorpus.artifact_class(artifact) do
      :typed_contract ->
        emit_drift_report(venue, artifact, "typed_contract", "blocking", target, expected, actual)

        Mix.raise(
          "#{artifact["id"]}: typed contract upstream drift — #{target} moved from pinned #{expected} to #{actual}"
        )

      :prose_docs ->
        handle_prose_drift!(venue, artifact, today, target, expected, actual)
    end
  end

  defp handle_prose_drift!(venue, artifact, today, target, expected, actual) do
    freshness = artifact["freshness"]
    checked_at = Date.from_iso8601!(freshness["checked_at"])
    age_days = Date.diff(today, checked_at)

    cond do
      freshness["status"] != "drift_detected" ->
        emit_drift_report(venue, artifact, "prose_docs", "unacknowledged", target, expected, actual)

        Mix.raise(
          "#{artifact["id"]}: unacknowledged prose/docs upstream drift — set freshness.status=drift_detected " <>
            "and freshness.checked_at to the acknowledgment date before the lane can pass"
        )

      age_days > @drift_acknowledgement_days ->
        emit_drift_report(venue, artifact, "prose_docs", "acknowledgement_stale", target, expected, actual)

        Mix.raise(
          "#{artifact["id"]}: stale prose/docs drift acknowledgment — #{age_days} days old exceeds the " <>
            "#{@drift_acknowledgement_days}-day limit; complete semantic review before refreshing the pin"
        )

      true ->
        Mix.shell().error("WARNING: #{venue}/#{artifact["id"]} prose/docs upstream drift remains acknowledged")
        emit_drift_report(venue, artifact, "prose_docs", "acknowledged", target, expected, actual)
    end
  end

  defp emit_drift_report(venue, artifact, class, status, target, expected, actual) do
    Mix.shell().info(
      "AUTHORITY_DRIFT venue=#{venue} artifact=#{artifact["id"]} class=#{class} status=#{status} " <>
        "checked_at=#{artifact["freshness"]["checked_at"]} target=#{target} expected=#{expected} actual=#{actual}"
    )
  end

  defp curl!(url) do
    curl = System.find_executable("curl") || Mix.raise("could not find curl executable")

    args = [
      "--fail",
      "--location",
      "--silent",
      "--show-error",
      "--max-time",
      Integer.to_string(@curl_timeout_seconds),
      url
    ]

    case System.cmd(curl, args, stderr_to_stdout: true) do
      {contents, 0} -> contents
      {output, status} -> Mix.raise("curl failed with status #{status} for #{url}:\n#{output}")
    end
  end

  defp git_head!(repository_url) do
    git = System.find_executable("git") || Mix.raise("could not find git executable")

    case System.cmd(git, ["ls-remote", repository_url, "HEAD"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split() |> List.first()
      {output, status} -> Mix.raise("git ls-remote failed with status #{status}:\n#{output}")
    end
  end

  defp ensure_no_positional!([]), do: :ok
  defp ensure_no_positional!(args), do: Mix.raise("unexpected arguments: #{Enum.join(args, " ")}")

  defp ensure_mode!(opts) do
    if Keyword.get(opts, :online, false) and Keyword.has_key?(opts, :fetch) do
      Mix.raise("--online and --fetch are mutually exclusive")
    end
  end
end
