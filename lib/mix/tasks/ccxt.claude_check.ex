defmodule Mix.Tasks.Ccxt.ClaudeCheck do
  @shortdoc "Gates CLAUDE.md mechanical claims against the tree"

  @moduledoc """
  Fails when CLAUDE.md names a module, Mix task, or repo path that does not
  exist, or when counted claims (signing patterns, Application children) drift
  from their machine-readable sources.

      mix ccxt.claude_check
      mix ccxt.claude_check --claude path/to/CLAUDE.md --root .

  Wired into `mix ci` alongside the AGENTS.md freshness gate. Pure filesystem /
  source parsing — safe for cold reviewer worktrees and `mix check.dispatch`.

  ## Regions gated (only these are parsed)

  | Region | Start heading | Purpose |
  |--------|---------------|---------|
  | The workbench boundary | `### … The workbench boundary` | which repo owns what, and the paths that claim it |
  | Venue authority index | `### Venue authority index` | per-venue manifest, recording, and carve-register paths |
  | Toolchain & check commands | `## Toolchain & check commands` | check-command table, promotion commands |
  | Running tests | `## Running tests` | command blocks and fixture-gate path claims |
  | Do NOT edit | `## Do NOT edit` | generated-vs-authored path claims |
  | Key modules | `### Key modules` | module tables, counted Signing / Application claims |
  | The trading domain layer | `## The trading domain layer` | domain module names and the boundary guard |

  A region runs from its heading until the next heading of the **same or a
  higher** level, so a `##` region keeps its `###` subsections while a `###`
  region still stops at the next `##`. Prose, doctrine, and design-rationale
  sections outside these regions are **out of scope**.

  ## What is checked

  1. **Modules** — backticked `Bourse.*` names (trailing `.*` wildcards skipped)
     must resolve to a `defmodule` under `lib/` or `test/support/`. Generator
     table short names under the Test Support heading expand to
     `Bourse.Test.Generator.<Name>`.
  2. **Mix tasks** — `mix ccxt.<task>` tokens and backticked
     `Mix.Tasks.Ccxt.*` names must resolve to a matching task module under
     `lib/mix/tasks/`.
  3. **Paths** — repo-relative file/dir paths in backticks or fenced command
     blocks must exist. Globs (`foo/*.json`) require the parent directory.
     Sibling (`../…`), absolute, URL, and angle-bracket templates are ignored.
  4. **Signing patterns** — the Key modules `Bourse.Signing` row's pattern list
     and optional `N patterns` count are cross-checked against literal
     `def sign(:atom, …)` clauses in `lib/bourse/signing.ex`.
  5. **Application children** — `Bourse.*` modules named in the Key modules
     `Bourse.Application` row (excluding `Bourse.Application` itself) must equal
     the child modules in `Bourse.Application.start/2`.

  ## What is deliberately not a failure

  - A module/task/path that exists in the tree but is never mentioned in
    CLAUDE.md (unlisted surfaces stay green).
  - Prose quality, doctrine, rationale, or whether a documented rule is good.
  - Auto-fixing CLAUDE.md (this task only grades).
  """

  use Mix.Task

  defmodule Finding do
    @moduledoc false

    @enforce_keys [:kind, :ref, :detail]
    defstruct [:kind, :ref, :detail]

    @type t :: %__MODULE__{kind: atom(), ref: String.t(), detail: String.t()}
  end

  @default_claude "CLAUDE.md"
  @default_root "."
  @default_signing "lib/bourse/signing.ex"
  @default_application "lib/bourse/application.ex"
  @switches [claude: :string, root: :string, signing: :string, application: :string]

  # {label, heading level, start pattern}. A region body runs from its heading
  # until the next heading of the same or a higher level, so a `##` region keeps
  # its `###` subsections and a `###` region still stops at the next `##`.
  @regions [
    {"The workbench boundary", 3, ~r/^### [^\n]*The workbench boundary\b/m},
    {"Venue authority index", 3, ~r/^### Venue authority index\b/m},
    {"Toolchain & check commands", 2, ~r/^## Toolchain & check commands\b/m},
    {"Running tests", 2, ~r/^## Running tests\b/m},
    {"Do NOT edit", 2, ~r/^## Do NOT edit\b/m},
    {"Key modules", 3, ~r/^### Key modules\b/m},
    {"The trading domain layer", 2, ~r/^## The trading domain layer\b/m}
  ]

  @module_pattern ~r/`(Bourse(?:\.[A-Za-z0-9_]+)+)(\.\*)?`/
  @mix_ccxt_task_pattern ~r/\bmix\s+(ccxt\.[a-z0-9_.]+)\b/
  @mix_task_module_pattern ~r/`(Mix\.Tasks\.Ccxt(?:\.[A-Za-z0-9_]+)+)`/
  @backtick_pattern ~r/`([^`\n]+)`/
  @generator_short_pattern ~r/^\| `([A-Z][A-Za-z0-9.]+)` /m
  @signing_count_pattern ~r/\b(\d+)\s+patterns\b/
  @signing_atom_pattern ~r/:([a-z][a-z0-9_]*)/
  @heading_stops %{2 => ~r/^\#{1,2} /m, 3 => ~r/^\#{1,3} /m}
  # Root filenames that appear without a directory component in gated regions.
  @root_files MapSet.new(~w(
    mix.exs AGENTS.md CHANGELOG.md CLAUDE.md ROADMAP.md BUGS.md
    CONTRIBUTING.md README.md COVERAGE.md LICENSE .sobelow-skips
  ))
  # Known roots also identify extensionless paths. Paths with a file extension,
  # glob, or trailing slash are mechanically recognizable without this list.
  @path_prefixes [
    "lib/",
    "test/",
    "priv/",
    "docs/",
    "scripts/",
    "native/",
    "roadmap/",
    ".claude/",
    "config/"
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: @switches)

    if positional != [] do
      Mix.raise("unexpected arguments: #{Enum.join(positional, " ")}")
    end

    check_paths!(
      Keyword.get(opts, :claude, @default_claude),
      Keyword.get(opts, :root, @default_root),
      Keyword.get(opts, :signing, @default_signing),
      Keyword.get(opts, :application, @default_application)
    )
  end

  @doc "Raises when CLAUDE.md mechanical claims drift from the tree."
  @spec check_paths!(Path.t(), Path.t(), Path.t(), Path.t()) :: :ok
  def check_paths!(claude_path, root, signing_path \\ @default_signing, application_path \\ @default_application) do
    findings = findings(claude_path, root, signing_path, application_path)

    if findings == [] do
      Mix.shell().info("CLAUDE.md mechanical claims match the tree.")
      :ok
    else
      Mix.raise(format_findings(findings))
    end
  end

  @doc """
  Returns every mechanical drift finding for the given paths.

  Each finding is a `Finding` with `:kind`, `:ref`, and `:detail`. Collects all
  findings in one pass (does not stop at the first stale reference).
  """
  @spec findings(Path.t(), Path.t(), Path.t(), Path.t()) :: [Finding.t()]
  def findings(claude_path, root, signing_path \\ @default_signing, application_path \\ @default_application) do
    claude = File.read!(claude_path)
    regions = extract_regions(claude)
    modules_index = index_modules(root)
    tasks_index = index_mix_tasks(root)

    region_findings =
      missing_region_findings(regions) ++
        Enum.flat_map(regions, fn {label, body} ->
          module_findings(body, label, modules_index) ++
            mix_task_findings(body, label, tasks_index) ++
            path_findings(body, label, root)
        end)

    # Must name a label from @regions — a typo here silently yields "", which
    # would make the signing and Application claims below find nothing to check
    # and pass unconditionally.
    key_modules = region_body(regions, "Key modules")

    region_findings ++
      signing_findings(key_modules, signing_path) ++
      application_findings(key_modules, application_path)
  end

  @doc "Splits CLAUDE.md into the gated region bodies."
  @spec extract_regions(String.t()) :: [{String.t(), String.t()}]
  def extract_regions(claude) do
    Enum.flat_map(@regions, fn {label, level, start_re} ->
      case Regex.run(start_re, claude, return: :index) do
        [{start_idx, _}] ->
          rest = binary_part(claude, start_idx, byte_size(claude) - start_idx)
          body = take_until_next_heading(rest, level)
          [{label, body}]

        nil ->
          []
      end
    end)
  end

  @doc "Indexes `defmodule` names under lib/ and test/support/."
  @spec index_modules(Path.t()) :: MapSet.t(String.t())
  def index_modules(root) do
    for dir <- ["lib", "test/support"],
        path <- Path.wildcard(Path.join(root, Path.join(dir, "**/*.{ex,exs}"))),
        mod <- defmodules_in_file(path),
        into: MapSet.new() do
      mod
    end
  end

  @doc "Indexes Mix.Tasks.Ccxt.* task names as `ccxt.foo_bar` strings."
  @spec index_mix_tasks(Path.t()) :: MapSet.t(String.t())
  def index_mix_tasks(root) do
    for path <- Path.wildcard(Path.join(root, "lib/mix/tasks/**/*.{ex,exs}")),
        mod <- defmodules_in_file(path),
        task_name <- mix_task_name(mod),
        into: MapSet.new() do
      task_name
    end
  end

  @doc "Literal `def sign(:atom, …)` pattern names from signing.ex source."
  @spec signing_patterns_from_source(String.t()) :: [String.t()]
  def signing_patterns_from_source(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, patterns} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head, _]} = node, patterns ->
          case sign_pattern(head) do
            nil -> {node, patterns}
            pattern -> {node, [Atom.to_string(pattern) | patterns]}
          end

        node, patterns ->
          {node, patterns}
      end)

    patterns
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Supervised child modules from Application.start/2 source."
  @spec application_children_from_source(String.t()) :: [String.t()]
  def application_children_from_source(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    aliases = aliases_from_ast(ast)
    children = find_children_list(ast) || []

    children
    |> Enum.flat_map(&child_module_name(&1, aliases))
    |> Enum.sort()
  end

  defp missing_region_findings(regions) do
    present = MapSet.new(regions, &elem(&1, 0))

    for {label, level, _pattern} <- @regions, not MapSet.member?(present, label) do
      %Finding{
        kind: :missing_region,
        ref: "#{String.duplicate("#", level)} #{label}",
        detail: "required gated CLAUDE.md region is missing"
      }
    end
  end

  @region_labels Enum.map(@regions, &elem(&1, 0))

  # A label that is not a gated region at all is a typo in this module, not a
  # drifted document — the guard raises FunctionClauseError instead of returning
  # "", which would make the caller's claim checks find nothing and pass
  # unconditionally. It is a guard rather than a body `not in` check because
  # every caller passes a literal: Dialyzer proves the body comparison can never
  # succeed and reports it as `exact_compare`, a warning tag dialyxir cannot even
  # format (it throws `:unknown_warning`, taking the whole run down with it).
  defp region_body(regions, label) when label in @region_labels do
    case List.keyfind(regions, label, 0) do
      {^label, body} -> body
      nil -> ""
    end
  end

  defp take_until_next_heading(rest, level) do
    # Drop the opening heading line, then cut at the next heading of the same or
    # a higher level so nested subsections stay inside their parent region.
    case String.split(rest, "\n", parts: 2) do
      [_heading] ->
        rest

      [_heading, after_heading] ->
        case Regex.run(Map.fetch!(@heading_stops, level), after_heading, return: :index) do
          [{idx, _}] -> binary_part(after_heading, 0, idx)
          nil -> after_heading
        end
    end
  end

  defp module_findings(body, label, index) do
    full = extract_bourse_modules(body)
    generators = extract_generator_shorts(body)
    claimed = Enum.uniq(full ++ generators)

    for name <- claimed, not module_exists?(name, index) do
      %Finding{
        kind: :missing_module,
        ref: name,
        detail:
          "named in #{label} but no defmodule in lib/ or test/support/ " <>
            "and module is not loadable"
      }
    end
  end

  # Source index covers hand-written modules; Code.ensure_loaded covers
  # compile-time generated exchange modules (lib/bourse/exchanges/*.ex macros).
  defp module_exists?(name, index) do
    MapSet.member?(index, name) or loadable_module?(name)
  end

  defp loadable_module?(name) when is_binary(name) do
    mod = Module.concat(String.split(name, "."))
    match?({:module, _}, Code.ensure_loaded(mod))
  end

  defp extract_bourse_modules(body) do
    @module_pattern
    |> Regex.scan(body)
    |> Enum.flat_map(fn
      [_, _name, ".*"] -> []
      [_, name] -> [name]
      [_, name, ""] -> [name]
    end)
  end

  defp extract_generator_shorts(body) do
    if String.contains?(body, "Bourse.Test.Generator") do
      @generator_short_pattern
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      # Only bare generator short names (SigningTests), not full Bourse.* cells.
      |> Enum.reject(&String.starts_with?(&1, "Bourse"))
      |> Enum.map(&("Bourse.Test.Generator." <> &1))
    else
      []
    end
  end

  defp mix_task_findings(body, label, index) do
    command_claims = Enum.map(extract_mix_bourse_tasks(body), &{&1, "mix #{&1}"})

    module_claims =
      @mix_task_module_pattern
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(fn module ->
        Enum.map(mix_task_name(module), &{&1, module})
      end)

    (command_claims ++ module_claims)
    |> Enum.uniq()
    |> Enum.reject(fn {name, _ref} -> MapSet.member?(index, name) end)
    |> Enum.map(fn {_name, ref} ->
      %Finding{
        kind: :missing_mix_task,
        ref: ref,
        detail: "named in #{label} but no Mix.Tasks module under lib/mix/tasks/"
      }
    end)
  end

  defp extract_mix_bourse_tasks(body) do
    @mix_ccxt_task_pattern
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(&mix_task_at_index(body, &1))
    |> Enum.uniq()
  end

  defp mix_task_at_index(body, [{start_idx, len} | _]) do
    # Capture group index is not in return: :index for the full match only —
    # re-slice the full match and parse the task name.
    full = binary_part(body, start_idx, len)

    cond do
      negated_at?(body, start_idx) -> []
      match = Regex.run(@mix_ccxt_task_pattern, full, capture: :all_but_first) -> match
      true -> []
    end
  end

  # "There is no mix ccxt.sync task" / "formerly removed mix ccxt.X" are not claims.
  defp negated_at?(body, start_idx) do
    window_start = max(0, start_idx - 48)
    window = binary_part(body, window_start, start_idx - window_start)
    String.match?(window, ~r/\b(?:no|not|never|without|removed|retired|deleted|formerly)\b/i)
  end

  defp path_findings(body, label, root) do
    body
    |> extract_paths()
    |> Enum.uniq()
    |> Enum.reject(&path_exists?(root, &1))
    |> Enum.map(fn path ->
      %Finding{kind: :missing_path, ref: path, detail: "named in #{label} but missing under #{root}"}
    end)
  end

  defp extract_paths(body) do
    from_backticks =
      @backtick_pattern
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()

    from_fences =
      ~r/```(?:bash|sh)?\n(.*?)```/s
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(&path_tokens_from_code/1)

    (from_backticks ++ from_fences)
    |> Enum.filter(&repo_relative_path?/1)
    |> Enum.map(&strip_glob/1)
  end

  defp path_tokens_from_code(block) do
    block
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.trim_trailing(&1, "\\"))
    |> Enum.filter(&String.contains?(&1, "/"))
  end

  defp strip_glob(path) do
    path
    |> String.replace(~r|/\*(\.[A-Za-z0-9]+)?$|, "")
    |> String.replace(~r|\*$|, "")
  end

  defp repo_relative_path?(path) do
    path != "" and
      not String.starts_with?(path, ["../", "./../", "/", "~", "http://", "https://"]) and
      not String.contains?(path, ["<", ">", " ", "{"]) and
      not function_arity?(path) and
      not String.match?(path, ~r/^[a-z]+:\/\//) and
      path_claim_shape?(path)
  end

  defp path_claim_shape?(path) do
    MapSet.member?(@root_files, path) or
      Enum.any?(@path_prefixes, &String.starts_with?(path, &1)) or
      String.ends_with?(path, "/") or
      (String.contains?(path, "/") and
         (String.contains?(path, "*") or Path.extname(path) != ""))
  end

  # `sign/4`, `Bourse.WS.subscribe/3`, `best_bid/ask/spread` — not filesystem paths.
  defp function_arity?(path) do
    String.match?(path, ~r/\A[A-Za-z_][A-Za-z0-9_.]*\/[\d\-]+\z/) or
      String.match?(path, ~r/\A[A-Za-z_][A-Za-z0-9_.]*\/[A-Za-z0-9_]+\/[A-Za-z0-9_]+\z/)
  end

  defp path_exists?(root, path) do
    File.exists?(Path.join(root, path))
  end

  defp signing_findings(key_modules_body, signing_path) do
    row = table_row_for(key_modules_body, "Bourse.Signing")

    if row == "" or not File.exists?(signing_path) do
      if row != "" and not File.exists?(signing_path) do
        [%Finding{kind: :missing_path, ref: signing_path, detail: "signing source for counted claim is missing"}]
      else
        []
      end
    else
      actual =
        signing_path
        |> File.read!()
        |> signing_patterns_from_source()

      claimed = signing_patterns_from_row(row)
      count_findings = signing_count_findings(row, actual)
      list_findings = signing_list_findings(claimed, actual)
      count_findings ++ list_findings
    end
  end

  defp signing_patterns_from_row(row) do
    # Prefer the explicit "Patterns: …" enumeration when present; otherwise all
    # :atoms in the row.
    segment =
      case Regex.run(~r/Patterns?:\s*(.+?)(?:\. Authoritative|\.\s*$)/s, row) do
        [_, listed] -> listed
        nil -> row
      end

    @signing_atom_pattern
    |> Regex.scan(segment, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp signing_count_findings(row, actual) do
    case Regex.run(@signing_count_pattern, row, capture: :all_but_first) do
      [digits] ->
        claimed = String.to_integer(digits)
        actual_n = length(actual)

        if claimed == actual_n do
          []
        else
          [
            %Finding{
              kind: :signing_count_mismatch,
              ref: "#{claimed} patterns",
              detail:
                "CLAUDE.md claims #{claimed} signing patterns; lib/bourse/signing.ex dispatch has #{actual_n}: #{inspect(actual)}"
            }
          ]
        end

      nil ->
        []
    end
  end

  defp signing_list_findings(claimed, actual) do
    # Only grade the list when CLAUDE.md enumerated patterns (non-empty claim set
    # that overlaps the real dispatch surface). Empty / no list → skip.
    if claimed == [] do
      []
    else
      # Restrict claimed atoms to those that look like signing patterns: anything
      # in actual, or any claimed atom that is not an actual pattern (stale).
      missing_from_tree = claimed -- actual
      missing_from_doc = actual -- claimed

      stale =
        for atom <- missing_from_tree do
          %Finding{
            kind: :signing_pattern_stale,
            ref: ":#{atom}",
            detail: "CLAUDE.md lists signing pattern not present in def sign/4 clauses"
          }
        end

      incomplete =
        for atom <- missing_from_doc do
          %Finding{
            kind: :signing_pattern_missing,
            ref: ":#{atom}",
            detail:
              "CLAUDE.md Signing row enumerates patterns but omits :#{atom} " <>
                "(source of truth: def sign/4 clauses in lib/bourse/signing.ex)"
          }
        end

      stale ++ incomplete
    end
  end

  defp application_findings(key_modules_body, application_path) do
    row = table_row_for(key_modules_body, "Bourse.Application")

    cond do
      row == "" ->
        []

      not File.exists?(application_path) ->
        [%Finding{kind: :missing_path, ref: application_path, detail: "application source for counted claim is missing"}]

      true ->
        actual =
          application_path
          |> File.read!()
          |> application_children_from_source()

        claimed =
          row
          |> extract_bourse_modules()
          |> Enum.reject(&(&1 == "Bourse.Application"))
          |> Enum.uniq()
          |> Enum.sort()

        if claimed == [] do
          # Row present but no Bourse.* children named — still require the prose
          # claim not to invent short names we cannot verify? Out of scope.
          # When the row uses only short names, treat "Supervises X + Y" as a
          # claim that must expand: require claimed short-name set via tokens.
          short_claim_findings(row, actual)
        else
          application_set_findings(claimed, actual)
        end
    end
  end

  defp short_claim_findings(row, actual) do
    # "Supervises RateLimiter + RateLimiter.State + Testnet." style.
    case Regex.run(~r/Supervises\s+(.+?)(?:\.|$)/s, row) do
      [_, list] ->
        claimed =
          list
          |> String.split(~r/\s*(?:\+|and|,)\s*/)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&short_to_module/1)
          |> Enum.sort()

        application_set_findings(claimed, actual)

      nil ->
        []
    end
  end

  defp short_to_module(name) do
    cond do
      String.starts_with?(name, "Bourse.") -> name
      String.starts_with?(name, "Signing.") -> "Bourse." <> name
      String.starts_with?(name, "WS.") -> "Bourse." <> name
      true -> "Bourse." <> name
    end
  end

  defp application_set_findings(claimed, actual) do
    missing_from_tree =
      for name <- claimed -- actual do
        %Finding{
          kind: :application_child_stale,
          ref: name,
          detail: "CLAUDE.md Application row names a child not in Bourse.Application.start/2"
        }
      end

    missing_from_doc =
      for name <- actual -- claimed do
        %Finding{
          kind: :application_child_missing,
          ref: name,
          detail:
            "Bourse.Application supervises #{name} but CLAUDE.md Application row omits it " <>
              "(source of truth: children list in lib/bourse/application.ex)"
        }
      end

    missing_from_tree ++ missing_from_doc
  end

  defp table_row_for(body, module_name) do
    pattern = ~r/^\| `#{Regex.escape(module_name)}` \|(.+)$/m

    case Regex.run(pattern, body) do
      [full | _] -> full
      nil -> ""
    end
  end

  defp defmodules_in_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        ~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do/m
        |> Regex.scan(contents, capture: :all_but_first)
        |> List.flatten()

      {:error, _} ->
        []
    end
  end

  defp mix_task_name("Mix.Tasks." <> rest) do
    parts = String.split(rest, ".")

    case parts do
      ["Ccxt"] ->
        ["ccxt"]

      ["Ccxt" | nested] ->
        # Mix.Tasks.Ccxt.OracleGate → ccxt.oracle_gate
        # Mix.Tasks.Ccxt.Helpers → not a mix task entry point we care about for
        # `mix ccxt.*` docs, but still indexable.
        snake = Enum.map_join(nested, ".", &Macro.underscore/1)

        ["ccxt." <> snake]

      _ ->
        []
    end
  end

  defp mix_task_name(_), do: []

  defp find_children_list(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:=, _, [{:children, _, _}, list]}, nil when is_list(list) ->
          {list, list}

        other, acc ->
          {other, acc}
      end)

    found
  end

  defp aliases_from_ast(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, aliases ->
          full = Enum.map_join(parts, ".", &to_string/1)
          {node, Map.put(aliases, parts |> List.last() |> to_string(), full)}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp child_module_name({:__aliases__, _, _} = module, aliases) do
    bourse_module_name(module, aliases)
  end

  defp child_module_name({{:., _, [module, :child_spec]}, _, _}, aliases) do
    bourse_module_name(module, aliases)
  end

  defp child_module_name({:{}, _, [module, _opts]}, aliases) do
    bourse_module_name(module, aliases)
  end

  defp child_module_name({module, _opts}, aliases) do
    bourse_module_name(module, aliases)
  end

  defp child_module_name(_child, _aliases), do: []

  defp bourse_module_name({:__aliases__, _, parts}, aliases) do
    [first | rest] = Enum.map(parts, &to_string/1)

    name =
      case Map.fetch(aliases, first) do
        {:ok, expanded} -> Enum.join([expanded | rest], ".")
        :error -> Enum.join([first | rest], ".")
      end

    if String.starts_with?(name, "Bourse."), do: [name], else: []
  end

  defp bourse_module_name(_module, _aliases), do: []

  defp sign_pattern({:sign, _, [pattern | _]}) when is_atom(pattern), do: pattern
  defp sign_pattern({:when, _, [head | _]}), do: sign_pattern(head)
  defp sign_pattern(_head), do: nil

  defp format_findings(findings) do
    lines =
      findings
      |> Enum.sort_by(fn f -> {f.kind, f.ref} end)
      |> Enum.map(fn f -> "  - [#{f.kind}] #{f.ref}: #{f.detail}" end)

    """
    CLAUDE.md mechanical claims drifted from the tree (#{length(findings)} finding(s)):
    #{Enum.join(lines, "\n")}

    Fix CLAUDE.md (or restore the missing module/task/path). This gate does not
    auto-edit the doc. Unlisted tree surfaces are intentionally not failures.
    """
  end
end
