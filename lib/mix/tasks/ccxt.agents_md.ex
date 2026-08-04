defmodule Mix.Tasks.Ccxt.AgentsMd do
  @shortdoc "Generates and freshness-checks AGENTS.md from CLAUDE.md"

  @moduledoc """
  Generates `AGENTS.md` by recursively inlining CLAUDE.md `@`-imports, and
  fails when the committed file has drifted.

      mix ccxt.agents_md            # write AGENTS.md
      mix ccxt.agents_md --check    # exit non-zero if AGENTS.md is stale/missing
      mix ccxt.agents_md --dry-run  # print rendered output, write nothing

  Wired into `mix check.dispatch` so every cross-family reviewer validates the
  rules document it is about to consume. Pure filesystem work — safe for cold
  harness worktrees.

  ## Input resolution (explicit only)

  Every `@`-import is resolved through a declared path:

  * **External** (`~/…` or absolute) — must appear in
    `priv/agents_includes/manifest.json`, which pins a repo-relative file and
    its SHA-256. Resolution never walks `$HOME` or any operator-local tree.
    A missing pin, missing file, or hash mismatch fails and names the source.
  * **Repo-relative** — resolved under the repository root. Absence fails and
    names the source.

  There is no silent fallback to an operator marketplace checkout or
  `~/.claude/includes/` tree. Recursion depth matches Claude Code's documented
  `@`-import limit (5 levels).
  """

  use Mix.Task

  @default_claude "CLAUDE.md"
  @default_agents "AGENTS.md"
  @default_manifest "priv/agents_includes/manifest.json"
  @default_root "."
  @header "<!-- Auto-generated from CLAUDE.md by mix ccxt.agents_md — do not edit manually -->\n\n"
  @import_line ~r/^@([^\s]+)\s*$/
  @switches [
    check: :boolean,
    dry_run: :boolean,
    claude: :string,
    agents: :string,
    manifest: :string,
    root: :string
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    if positional != [] do
      Mix.raise("unexpected arguments: #{Enum.join(positional, " ")}")
    end

    mode =
      cond do
        Keyword.get(opts, :check, false) -> :check
        Keyword.get(opts, :dry_run, false) -> :dry_run
        true -> :write
      end

    run_mode(
      mode,
      Keyword.get(opts, :claude, @default_claude),
      Keyword.get(opts, :agents, @default_agents),
      Keyword.get(opts, :manifest, @default_manifest),
      Keyword.get(opts, :root, @default_root)
    )
  end

  @doc "Renders AGENTS.md content from CLAUDE.md and the include manifest."
  @spec render(Path.t(), Path.t(), Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def render(claude_path, manifest_path, root \\ @default_root) do
    with {:ok, claude} <- read_text(claude_path, "CLAUDE.md"),
         {:ok, manifest} <- load_manifest(manifest_path, root) do
      case inline_text(claude, 1, claude_path, manifest, root, []) do
        {:ok, body, _stack} -> {:ok, @header <> body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Raises when committed AGENTS.md drifts from a fresh render."
  @spec check!(Path.t(), Path.t(), Path.t(), Path.t()) :: :ok
  def check!(claude_path, agents_path, manifest_path, root \\ @default_root) do
    case check(claude_path, agents_path, manifest_path, root) do
      :ok ->
        Mix.shell().info("OK: #{agents_path} is up to date")
        :ok

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  @doc "Returns `:ok` or `{:error, reason}` for AGENTS.md freshness."
  @spec check(Path.t(), Path.t(), Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def check(claude_path, agents_path, manifest_path, root \\ @default_root) do
    case render(claude_path, manifest_path, root) do
      {:ok, rendered} -> compare_agents(agents_path, rendered)
      {:error, reason} -> {:error, reason}
    end
  end

  defp compare_agents(agents_path, rendered) do
    case File.read(agents_path) do
      {:ok, ^rendered} ->
        :ok

      {:ok, _existing} ->
        {:error,
         "STALE: #{agents_path} has drifted from CLAUDE.md (+ pinned @-imports) — " <>
           "run `mix ccxt.agents_md`"}

      {:error, :enoent} ->
        {:error, "STALE: #{agents_path} is missing — run `mix ccxt.agents_md`"}

      {:error, reason} ->
        {:error, "cannot read #{agents_path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Writes rendered AGENTS.md to disk."
  @spec write!(Path.t(), Path.t(), Path.t(), Path.t()) :: :ok
  def write!(claude_path, agents_path, manifest_path, root \\ @default_root) do
    case render(claude_path, manifest_path, root) do
      {:ok, rendered} ->
        File.write!(agents_path, rendered)
        Mix.shell().info("Wrote #{agents_path}")
        :ok

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp run_mode(:check, claude, agents, manifest, root), do: check!(claude, agents, manifest, root)
  defp run_mode(:write, claude, agents, manifest, root), do: write!(claude, agents, manifest, root)

  defp run_mode(:dry_run, claude, _agents, manifest, root) do
    case render(claude, manifest, root) do
      {:ok, rendered} ->
        IO.write(rendered)
        Mix.shell().info("--- Summary ---")
        Mix.shell().info("Dry run — would write AGENTS.md")
        :ok

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp load_manifest(path, root) do
    abs = resolve_under_root(path, root)

    with {:ok, contents} <- read_text(abs, "include manifest"),
         {:ok, decoded} <- decode_manifest(contents, abs) do
      includes =
        decoded
        |> Map.fetch!("includes")
        |> Map.new(fn {declared, entry} ->
          {declared,
           %{
             path: Map.fetch!(entry, "path"),
             sha256: Map.fetch!(entry, "sha256"),
             bytes: Map.get(entry, "bytes")
           }}
        end)

      {:ok,
       %{
         max_depth: Map.get(decoded, "max_depth", 5),
         includes: includes
       }}
    end
  end

  defp decode_manifest(contents, path) do
    case Jason.decode(contents) do
      {:ok, %{} = map} ->
        if is_map(Map.get(map, "includes")) do
          {:ok, map}
        else
          {:error, "include manifest #{path} is missing an object \"includes\" map"}
        end

      {:ok, _} ->
        {:error, "include manifest #{path} must be a JSON object"}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "include manifest #{path} is not valid JSON: #{Exception.message(err)}"}
    end
  end

  defp inline_text(text, depth, label, manifest, root, stack) do
    if depth > manifest.max_depth do
      {:error, "ERROR: @-import depth exceeded #{manifest.max_depth} at #{label}"}
    else
      text
      |> content_lines()
      |> reduce_lines(depth, label, manifest, root, stack, [])
    end
  end

  # Mirror bash `while read` + always-append-$'\n': a trailing newline on the
  # source does not produce an extra empty line, but every content line (and a
  # final line without a trailing newline) still emits a terminating \n.
  defp content_lines(text) do
    case String.split(text, "\n", trim: false) do
      [] ->
        []

      parts ->
        if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    end
  end

  defp reduce_lines([], _depth, _label, _manifest, _root, stack, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), stack}
  end

  defp reduce_lines([line | rest], depth, label, manifest, root, stack, acc) do
    case Regex.run(@import_line, line, capture: :all_but_first) do
      [raw] ->
        with {:ok, body, stack} <- inline_import(raw, depth, manifest, root, stack) do
          marker = "<!-- @-import: #{raw} -->\n"
          reduce_lines(rest, depth, label, manifest, root, stack, [body, marker | acc])
        end

      nil ->
        reduce_lines(rest, depth, label, manifest, root, stack, [[line, "\n"] | acc])
    end
  end

  defp inline_import(raw, depth, manifest, root, stack) do
    if Enum.member?(stack, raw) do
      {:error, "ERROR: cyclic @-import involving #{raw}"}
    else
      load_and_inline_import(raw, depth, manifest, root, stack)
    end
  end

  defp load_and_inline_import(raw, depth, manifest, root, stack) do
    with {:ok, abs_path} <- resolve_import(raw, manifest, root),
         {:ok, contents} <- abs_path |> File.read() |> read_ok(raw, abs_path),
         :ok <- verify_pin(raw, abs_path, contents, manifest),
         {:ok, body, _stack} <-
           inline_text(contents, depth + 1, raw, manifest, root, [raw | stack]) do
      # Match the marketplace script: imported body + trailing blank line.
      {:ok, body <> "\n", stack}
    end
  end

  defp resolve_import(raw, manifest, root) do
    if external_import?(raw) do
      case Map.fetch(manifest.includes, raw) do
        {:ok, %{path: rel}} ->
          resolve_pinned_import(raw, rel, root)

        :error ->
          {:error,
           "ERROR: undeclared external @-import: #{raw}\n" <>
             "Pin it in priv/agents_includes/manifest.json (repo path + sha256). " <>
             "Resolution never falls back to $HOME or an operator marketplace checkout."}
      end
    else
      resolve_repo_import(raw, root)
    end
  end

  defp resolve_pinned_import(raw, path, root) do
    if Path.type(path) == :relative and not String.starts_with?(path, "~") do
      resolve_inside_root(path, root, raw)
    else
      {:error, "ERROR: pinned include path for #{raw} must be repository-relative: #{inspect(path)}"}
    end
  end

  defp resolve_repo_import(raw, root), do: resolve_inside_root(raw, root, raw)

  defp resolve_inside_root(path, root, raw) do
    root = Path.expand(root)
    resolved = Path.expand(path, root)
    relative = Path.relative_to(resolved, root)

    if Path.type(relative) == :absolute or relative == ".." or
         String.starts_with?(relative, "../") do
      {:error, "ERROR: @-import #{raw} resolves outside repository root #{root}"}
    else
      {:ok, resolved}
    end
  end

  defp verify_pin(raw, abs_path, contents, manifest) do
    if external_import?(raw) do
      entry = Map.fetch!(manifest.includes, raw)
      actual = sha256_hex(contents)

      cond do
        entry.sha256 != actual ->
          {:error,
           "ERROR: pinned include hash mismatch for #{raw}\n" <>
             "  path: #{entry.path}\n" <>
             "  expected sha256: #{entry.sha256}\n" <>
             "  actual sha256:   #{actual}\n" <>
             "Refresh the pin after intentionally updating the vendored file."}

        is_integer(entry.bytes) and entry.bytes != byte_size(contents) ->
          {:error,
           "ERROR: pinned include byte-size mismatch for #{raw}\n" <>
             "  path: #{entry.path}\n" <>
             "  expected bytes: #{entry.bytes}\n" <>
             "  actual bytes:   #{byte_size(contents)}"}

        true ->
          :ok
      end
    else
      # Repo-relative imports: file presence is the pin; abs_path already read.
      _ = abs_path
      :ok
    end
  end

  defp external_import?(raw) do
    String.starts_with?(raw, "~/") or String.starts_with?(raw, "/")
  end

  defp resolve_under_root(path, root) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path, root)
    end
  end

  defp read_text(path, label) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:error, "ERROR: #{label} not found at #{path}"}

      {:error, reason} ->
        {:error, "ERROR: cannot read #{label} at #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp read_ok({:ok, contents}, _raw, _abs), do: {:ok, contents}

  defp read_ok({:error, :enoent}, raw, abs) do
    {:error,
     "ERROR: cannot read @-import: #{raw} (resolved to #{abs})\n" <>
       "The declared source is missing from this checkout."}
  end

  defp read_ok({:error, reason}, raw, abs) do
    {:error, "ERROR: cannot read @-import: #{raw} (resolved to #{abs}): #{:file.format_error(reason)}"}
  end

  defp sha256_hex(contents) do
    :sha256
    |> :crypto.hash(contents)
    |> Base.encode16(case: :lower)
  end
end
