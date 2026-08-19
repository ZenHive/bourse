defmodule Bourse.MixProject do
  use Mix.Project

  @version "0.6.0"
  @source_url "https://github.com/ZenHive/bourse"
  @runtime_manifest "priv/specs/json/runtime_support.json"
  @capability_surface "priv/specs/json/capability_surface.json"
  @runtime_venues @runtime_manifest |> File.read!() |> :json.decode() |> Map.fetch!("venues")

  def project do
    [
      app: :bourse,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "Elixir client for eleven provider-authored cryptocurrency exchange integrations.",
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: dialyzer(),
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "readme",
      # `docs/authored-specs.md` is deliberately absent: it is the maintainer
      # authoring loop, and every one of its links points at something hexdocs
      # withholds — the eleven carve registers under `docs/authored-spec-carves/`
      # and the repo-internal `mix ccxt.*` tasks. Rendered here it produced ten
      # broken links; README links it on GitHub instead, where they resolve.
      extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md"],
      source_url_pattern: "#{@source_url}/blob/main/%{path}#L%{line}",
      description: "Unified and raw REST APIs for ten complete provider-authored exchange integrations.",
      # Docs mirror the package: only `ccxt.build_lighter_signer` ships, so the
      # repo-internal tasks must not appear on hexdocs as tasks consumers can run.
      # `filter_modules` is a KEEP predicate — true documents the module.
      filter_modules: &__MODULE__.document_module?/2,
      groups_for_modules: [
        Exchanges: ~r/^Elixir\.Bourse\.[A-Z][a-zA-Z0-9]+$/,
        Signing: ~r/^Elixir\.Bourse\.Signing\./,
        WebSocket: ~r/^Elixir\.Bourse\.WS\./,
        "Core API": [
          Bourse,
          Bourse.Exchange,
          Bourse.Registry,
          Bourse.Spec,
          Bourse.Unified,
          Bourse.UnifiedMethod,
          Bourse.Symbol,
          Bourse.Parser,
          Bourse.Dispatch,
          Bourse.HTTP,
          Bourse.Credentials,
          Bourse.Error,
          Bourse.MCP,
          Bourse.Multi,
          Bourse.Exchanges
        ]
      ]
    ]
  end

  # Repo-internal verification tooling: venue promotion grades a candidate
  # against this repo's reality manifests, and the oracle / recording / replay /
  # drift cluster reads `test/fixtures/**` and `priv/reference_cache/`. None of
  # those roots are packaged, so a shipped copy could only fail on missing
  # files — and it drags this repo's `:dev`/`:test` toolchain into a consumer's
  # compile (`Req.Plug` exists only from req 0.7 and only behind `:plug`).
  # Every entry here is reached solely from tests and from the `lib/mix/tasks`
  # tooling that `package/0` already withholds.
  @unpackaged_prefixes ~w(
    spec/promotion
    exchange_acceptance_fixtures
    public_accepted_requests
    oracle_provenance
    oracle_label
    replay_exchange
    recorded_response_fixtures
    live_drift
    live_lane
  )

  @doc """
  ExDoc `:filter_modules` predicate — true keeps the module in the docs.

  Drops everything `package/0` deliberately leaves out of the tarball, so
  hexdocs never advertises a module or task a consumer does not receive: the
  `mix ccxt.*` tasks (all but `ccxt.build_lighter_signer`, the one
  consumer-facing build step) and the repo-internal tooling named by
  `@unpackaged_prefixes`.
  """
  @spec document_module?(module(), map()) :: boolean()
  def document_module?(module, _metadata) do
    name = inspect(module)

    documented_task?(name) and not unpackaged_module?(name)
  end

  defp documented_task?(name) do
    not String.starts_with?(name, "Mix.Tasks.Ccxt.") or
      name == "Mix.Tasks.Ccxt.BuildLighterSigner"
  end

  defp unpackaged_module?(name) do
    Enum.any?(@unpackaged_prefixes, fn prefix ->
      root = "Bourse." <> Macro.camelize(prefix)

      name == root or String.starts_with?(name, root <> ".")
    end)
  end

  defp package do
    runtime_specs =
      Enum.map(@runtime_venues, &"priv/specs/json/output/authored/#{&1}.json")

    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # `lib/mix/tasks` is repo-internal verification tooling: every task but the
      # Lighter build reads paths that are deliberately unpackaged
      # (`test/fixtures`, the reference cache), so shipping them would put
      # `mix help` entries in consumer projects that fail on a missing file.
      # `ccxt.build_lighter_signer` is the one consumer-facing task — README
      # documents it as the prerequisite for private Lighter calls.
      files:
        client_lib_files() ++
          ~w(lib/bourse.ex lib/mix/tasks/ccxt.build_lighter_signer.ex) ++
          ~w(native/lighter_signer mix.exs README.md LICENSE NOTICE) ++
          [@runtime_manifest, @capability_surface | runtime_specs]
    ]
  end

  # Hex packages a listed *directory* recursively, so any directory entry that
  # survives here re-ships an excluded subtree whatever the prefix list says: a
  # bare `lib/bourse/option_saga` did it at depth 1, and `lib/bourse/spec` — whose
  # relative path is "spec", matching no prefix — did it again at depth 2 for
  # `spec/promotion/**`. Dropping directories outright removes the class instead
  # of naming one more prefix; `unpackaged_path?/1` then only has to judge files.
  defp client_lib_files do
    "lib/bourse/**"
    |> Path.wildcard()
    |> Enum.reject(&(File.dir?(&1) or unpackaged_path?(&1)))
  end

  defp unpackaged_path?(path) do
    rest = Path.relative_to(path, "lib/bourse")

    Enum.any?(
      @unpackaged_prefixes,
      &(rest == "#{&1}.ex" or String.starts_with?(rest, "#{&1}/"))
    )
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :yaml_elixir]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.json": :test,
        "dialyzer.json": :dev,
        "ccxt.oracle_gate": :test
      ]
    ]
  end

  def application do
    [
      mod: {Bourse.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Dev/test tooling
      {:ex_unit_json, "~> 0.6", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2.1", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.12.2", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.15.0", only: [:dev, :test], runtime: false},
      # CVE tripwire: `mix deps.audit` checks mix.lock against the advisory DB
      # (hex.audit only catches retired packages). Wired into precommit.full + ci.
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:yaml_elixir, "~> 2.12", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:doctor, "~> 0.23.0", only: [:dev, :test], runtime: false},

      # Tidewave for Claude Code MCP integration (non-Phoenix needs bandit)
      {:tidewave, "~> 0.9.0", only: :dev},
      {:bandit, "~> 1.12.0", only: :dev},

      # Code analysis tools
      {:ex_dna, "~> 1.5.3", only: [:dev, :test], runtime: false},
      # reach 2.8.1 pins ex_ast ~> 0.12.0; override verified against mix reach.check
      {:ex_ast, "~> 0.13.0", only: [:dev, :test], runtime: false, override: true},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8.1", only: [:dev, :test], runtime: false},
      # reach references Boxart.Render.* unconditionally; boxart is
      # `optional: true` in reach's hex manifest, so we pull it in here.
      {:boxart, "~> 0.3.3", only: [:dev, :test], runtime: false},

      # Plug.Conn for Req.Test stubs with custom status codes (also needed by tidewave in :dev)
      {:plug, "~> 1.20", only: [:dev, :test]},

      # Runtime dependencies
      # decimal — arbitrary-precision decimal for money-exact response normalization
      # (Bourse `Precise.stringMul`/`stringDiv` parity: e.g. trade cost = amount × price
      # without float drift). Previously only transitively present via dev/test `doctor`.
      {:decimal, "~> 3.1"},
      {:jason, "~> 1.4.5"},
      {:req, "~> 0.6.1 or ~> 0.7.0"},
      {:fuse, "~> 2.5.0"},
      {:telemetry, "~> 1.4.2"},

      # Self-describing APIs — emit_api/3 (for-comprehension api declarations,
      # used in lib/bourse.ex) ships in descripex 0.11.0; vendor fork retired.
      {:descripex, "~> 0.12.0"},

      # Custom DEX signing (hyperliquid + derive): EIP-712 / msgpack / secp256k1.
      # msgpax — canonical MessagePack for Hyperliquid action hashing.
      # ex_keccak — Keccak-256 NIF (EIP-712 struct/domain hashing).
      # ex_secp256k1 — RFC-6979 deterministic ECDSA with recovery id (signature r/s/v).
      {:msgpax, "~> 2.4"},
      {:ex_keccak, "~> 0.7.8"},
      {:ex_secp256k1, "~> 0.8.0"},

      # WebSocket client (Gun-based, 5-function API + Deribit heartbeat + reconnection)
      {:zen_websocket, "~> 0.6.0"}
    ]
  end

  defp aliases do
    [
      tidewave: [
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4029) end)'"
      ],
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        # TODO(Task N) markers are first-class here — don't fail credo on them.
        "credo --strict --ignore TagTODO,TagFIXME",
        "doctor --raise",
        # Hash-based `.sobelow-skips` (this repo's hook ignores inline comments).
        "sobelow --skip",
        # `preferred_envs` (cli/0) is ignored for alias steps — set MIX_ENV
        # explicitly so test.json runs in :test (a bare alias step inherits the
        # alias's env, not :test). `cmd env VAR=val ...` so the assignment reaches
        # the subprocess env, not System.cmd's executable slot. test.json excludes
        # most integration tags by default; this is the offline unit + signing gate.
        "cmd env MIX_ENV=test mix test.json --quiet --exclude integration"
      ],
      # Dispatch-scale reviewer hint (the registered harness `check_command`).
      # `precommit` (offline unit + signing gate) plus the clone + architecture/smell
      # analyzers a cold reviewer worktree would otherwise never run (they're only
      # host-PostToolUse-hook-run locally). No dialyzer (a cold harness worktree
      # cold-builds the PLT for minutes → `review_stuck`).
      "check.dispatch": [
        "precommit",
        # Binary reality gate over recordings, accepted requests, and recorded
        # errors. The committed exact-set baseline rejects lost provenance.
        "cmd env MIX_ENV=test mix ccxt.oracle_gate",
        # Cheap, network-free provider-authority structure/hash and exact-error
        # consistency checks. Remote freshness belongs to the weekly drift lane.
        "ccxt.authority_check",
        "ccxt.error_authority",
        "ccxt.check_lighter_signer",
        # CLAUDE.md's mechanical claims (modules, mix tasks, repo paths, the
        # signing pattern list, Application children) vs the tree, plus AGENTS.md
        # freshness — the cross-family reviewer reads AGENTS.md, not CLAUDE.md,
        # so a stale render makes it grade against rules we already changed.
        "ccxt.claude_check",
        "ccxt.agents_md --check",
        "ex_dna --max-clones 0",
        # `--strict` fails the gate on smell findings — no baseline/suppression;
        # findings are fixed, not grandfathered. Reach derives architecture
        # sources from the active Mix environment, while `--path` pins smell
        # sources; pin both so callers always grade lib/.
        "cmd env MIX_ENV=dev mix reach.check --arch --smells --strict --path lib"
      ],
      # GHSA-w4f7-4cxr-rv3c pairs cowboy + gun; its gun rows carry cowboy's
      # numbers ("first patched 2.16.0" — gun has no 2.16.x), so mix_audit
      # flags gun 2.5.0 although gun's own vulnerable range is < 2.4.0.
      # Verified against the advisory 2026-07-30; drop when the DB row is fixed.
      "deps.audit": "deps.audit --ignore-advisory-ids GHSA-w4f7-4cxr-rv3c",
      # Local pre-PR / post-merge-audit gate — adds dialyzer. SPLIT out because a
      # cold harness worktree cold-builds the PLT (minutes) → `review_stuck`.
      # `--cover` is omitted everywhere here (`:cover` instruments every loaded
      # beam, multi-GB spike on cold trees); run coverage explicitly via
      # `mix test.json --cover` per the critical-rules gate.
      "precommit.full": ["precommit", "deps.audit", "dialyzer.json --quiet"],
      # Comprehensive pre-PR / CI gate: the dispatch gate + dialyzer.
      ci: [
        "check.dispatch",
        # Builds and unpacks the real Hex tarball. Kept out of `precommit` (it
        # shells out to `mix hex.build` per run) but required here, because Hex's
        # recursive directory expansion is invisible in `package[:files]` — see
        # `test/mix_project_test.exs`.
        "cmd env MIX_ENV=test mix test.json --quiet --only package",
        "deps.audit",
        "dialyzer.json --quiet"
      ]
    ]
  end
end
