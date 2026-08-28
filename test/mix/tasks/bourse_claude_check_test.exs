defmodule Mix.Tasks.Bourse.ClaudeCheckTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bourse.ClaudeCheck

  describe "extract_regions/1" do
    test "returns only the gated headings" do
      claude = """
      ### Outside
      `Bourse.Missing` and `docs/nope.md`
      ### The workbench is dissolved
      | Deribit | `priv/venues/deribit/authority/manifest.json` |
      ### Venue authority index
      mix bourse.oracle_gate
      ### Key modules
      | `Bourse.Signing` | routing 1 patterns. Patterns: `:custom`. |
      ## Toolchain & check commands
      | Tests | `mix test.json --quiet` |
      ## Running tests
      ```bash
      mix bourse.classify_signing
      test/bourse/deleted_test.exs
      ```
      ## Do NOT edit
      mix bourse.authority_check
      ## The trading domain layer
      `Bourse.PortfolioRisk`
      ## Critical design decisions
      `Bourse.AlsoMissing`
      """

      regions = ClaudeCheck.extract_regions(claude)
      labels = Enum.map(regions, &elem(&1, 0))

      assert labels == [
               "The workbench is dissolved",
               "Venue authority index",
               "Toolchain & check commands",
               "Running tests",
               "Do NOT edit",
               "Key modules",
               "The trading domain layer"
             ]

      refute Enum.any?(regions, fn {_, body} -> String.contains?(body, "Bourse.Missing") end)
      refute Enum.any?(regions, fn {_, body} -> String.contains?(body, "Bourse.AlsoMissing") end)
    end

    test "a level-2 region keeps its subsections but stops at the next level-2" do
      claude = """
      ## Toolchain & check commands
      | Tests | `mix test.json` |
      ### A subsection of the toolchain region
      `docs/inside.md`
      ## Running tests
      `docs/outside.md`
      """

      regions = ClaudeCheck.extract_regions(claude)
      assert {_, toolchain} = List.keyfind(regions, "Toolchain & check commands", 0)

      assert toolchain =~ "docs/inside.md"
      refute toolchain =~ "docs/outside.md"
    end

    test "missing required headings are findings instead of disabling coverage" do
      root = temp_tree!()

      write!(root, "CLAUDE.md", """
      ### Venue authority index
      present
      ## Do NOT edit
      present
      """)

      findings = ClaudeCheck.findings(Path.join(root, "CLAUDE.md"), root)
      refs = Enum.map(findings, & &1.ref)

      assert "## Toolchain & check commands" in refs
      assert "### The workbench is dissolved" in refs
      assert "### Key modules" in refs
      assert "## Running tests" in refs
      assert "## The trading domain layer" in refs
      refute "### Venue authority index" in refs
      refute "## Do NOT edit" in refs
    end
  end

  describe "module / mix task / path findings" do
    test "reports every stale reference in one run" do
      root = temp_tree!()

      claude = """
      ### The workbench is dissolved
      | Nope | `priv/venues/nope/authority/manifest.json` |
      ### Venue authority index
      no tasks here
      ### Key modules
      | `Bourse.Present` | ok |
      | `Bourse.MissingModule` | gone |
      | `Bourse.WS.Subscription.*` | wildcard — ignored |
      #### Test Support (`Bourse.Test.Generator.*`)
      | `PresentGen` | exists |
      | `MissingGen` | gone |
      | `Bourse.Signing` | routing 1 patterns. Patterns: `:custom`. Authoritative table lives in the module's `@moduledoc`. |
      | `Bourse.Application` | Supervises `Bourse.RateLimiter` + `Bourse.Testnet`. |
      ## Toolchain & check commands
      | X | `mix bourse.oracle_gate` |
      | Y | `mix bourse.does_not_exist` |
      | Z | `Mix.Tasks.Bourse.AlsoMissing` |
      ## Running tests
      ```bash
      mix bourse.classify_signing
      test/bourse/missing_file.exs
      test/bourse/present_file.exs
      ```
      `ccxt-distill/fixtures/signing/*.json`
      ## Do NOT edit
      mix bourse.authority_missing
      `scripts/missing_authority.sh`
      ## The trading domain layer
      ok
      """

      write!(root, "CLAUDE.md", claude)
      write!(root, "lib/bourse/present.ex", "defmodule Bourse.Present do\nend\n")
      write!(root, "lib/bourse/rate_limiter.ex", "defmodule Bourse.RateLimiter do\nend\n")
      write!(root, "lib/bourse/testnet.ex", "defmodule Bourse.Testnet do\nend\n")
      write!(root, "lib/bourse/signing.ex", "defmodule Bourse.Signing do\n  def sign(:custom, a, b, c), do: :ok\nend\n")

      write!(
        root,
        "lib/bourse/application.ex",
        """
        defmodule Bourse.Application do
          def start(_type, _args) do
            children = [Bourse.RateLimiter, Bourse.Testnet]
            Supervisor.start_link(children, strategy: :one_for_one)
          end
        end
        """
      )

      write!(root, "lib/mix/tasks/bourse.oracle_gate.ex", """
      defmodule Mix.Tasks.Bourse.OracleGate do
        use Mix.Task
        def run(_), do: :ok
      end
      """)

      write!(root, "lib/mix/tasks/bourse.classify_signing.ex", """
      defmodule Mix.Tasks.Bourse.ClassifySigning do
        use Mix.Task
        def run(_), do: :ok
      end
      """)

      write!(
        root,
        "test/support/test_generator/present_gen.ex",
        "defmodule Bourse.Test.Generator.PresentGen do\nend\n"
      )

      write!(root, "test/bourse/present_file.exs", "# present\n")

      findings =
        ClaudeCheck.findings(
          Path.join(root, "CLAUDE.md"),
          root,
          Path.join(root, "lib/bourse/signing.ex"),
          Path.join(root, "lib/bourse/application.ex")
        )

      refs = Enum.map(findings, & &1.ref)

      assert "Bourse.MissingModule" in refs
      assert "Bourse.Test.Generator.MissingGen" in refs
      assert "mix bourse.does_not_exist" in refs
      assert "mix bourse.authority_missing" in refs
      assert "priv/venues/nope/authority/manifest.json" in refs
      assert "Mix.Tasks.Bourse.AlsoMissing" in refs
      assert "scripts/missing_authority.sh" in refs
      assert "test/bourse/missing_file.exs" in refs
      assert "ccxt-distill/fixtures/signing" in refs

      # Present surface must not be reported.
      refute "Bourse.Present" in refs
      refute "Bourse.Test.Generator.PresentGen" in refs
      refute "mix bourse.oracle_gate" in refs
      refute "mix bourse.classify_signing" in refs
      refute "test/bourse/present_file.exs" in refs
      # Wildcard modules are not concrete claims.
      refute Enum.any?(refs, &String.contains?(&1, "Subscription"))

      # Collect-all: more than one finding class in one run.
      assert length(findings) >= 4
    end

    test "unlisted tree modules do not fail the gate" do
      root = temp_tree!()

      claude = """
      ### The workbench is dissolved
      ok
      ### Venue authority index
      ok
      ### Key modules
      | `Bourse.OnlyOne` | sole claim |
      | `Bourse.Signing` | routing 1 patterns. Patterns: `:custom`. Authoritative table lives in the module's `@moduledoc`. |
      | `Bourse.Application` | Supervises `Bourse.RateLimiter`. |
      ## Toolchain & check commands
      ok
      ## Running tests
      ok
      ## Do NOT edit
      ok
      ## The trading domain layer
      ok
      """

      write!(root, "CLAUDE.md", claude)
      write!(root, "lib/bourse/only_one.ex", "defmodule Bourse.OnlyOne do\nend\n")
      write!(root, "lib/bourse/unlisted.ex", "defmodule Bourse.Unlisted do\nend\n")
      write!(root, "lib/bourse/rate_limiter.ex", "defmodule Bourse.RateLimiter do\nend\n")
      write!(root, "lib/bourse/signing.ex", "defmodule Bourse.Signing do\n  def sign(:custom, a, b, c), do: :ok\nend\n")

      write!(
        root,
        "lib/bourse/application.ex",
        """
        defmodule Bourse.Application do
          def start(_type, _args) do
            children = [Bourse.RateLimiter]
            Supervisor.start_link(children, strategy: :one_for_one)
          end
        end
        """
      )

      assert :ok =
               ClaudeCheck.check_paths!(
                 Path.join(root, "CLAUDE.md"),
                 root,
                 Path.join(root, "lib/bourse/signing.ex"),
                 Path.join(root, "lib/bourse/application.ex")
               )
    end
  end

  describe "signing pattern counted claim" do
    test "fails when the listed set or count drifts from def sign/4" do
      root = temp_tree!()

      claude = """
      ### The workbench is dissolved
      x
      ### Venue authority index
      x
      ### Key modules
      | `Bourse.Signing` | routing 12 patterns. Patterns: `:hmac_sha256_query`, `:custom`. Authoritative table lives in the module's `@moduledoc`. |
      | `Bourse.Application` | Supervises `Bourse.RateLimiter`. |
      ## Toolchain & check commands
      x
      ## Running tests
      x
      ## Do NOT edit
      x
      ## The trading domain layer
      ok
      """

      write!(root, "CLAUDE.md", claude)

      write!(root, "lib/bourse/signing.ex", """
      defmodule Bourse.Signing do
        def sign(:hmac_sha256_query, a, b, c), do: :ok
        def sign(:lighter, a, b, c), do: :ok
        def sign(:custom, a, b, c), do: :ok
      end
      """)

      write!(
        root,
        "lib/bourse/application.ex",
        """
        defmodule Bourse.Application do
          def start(_type, _args) do
            children = [Bourse.RateLimiter]
            Supervisor.start_link(children, strategy: :one_for_one)
          end
        end
        """
      )

      findings =
        ClaudeCheck.findings(
          Path.join(root, "CLAUDE.md"),
          root,
          Path.join(root, "lib/bourse/signing.ex"),
          Path.join(root, "lib/bourse/application.ex")
        )

      kinds = Enum.map(findings, & &1.kind)
      assert :signing_count_mismatch in kinds
      assert :signing_pattern_missing in kinds
      assert Enum.any?(findings, &(&1.ref == ":lighter"))
    end
  end

  describe "application children counted claim" do
    test "fails when CLAUDE omits a supervised child" do
      root = temp_tree!()

      claude = """
      ### The workbench is dissolved
      x
      ### Venue authority index
      x
      ### Key modules
      | `Bourse.Signing` | routing 1 patterns. Patterns: `:custom`. Authoritative table lives in the module's `@moduledoc`. |
      | `Bourse.Application` | Supervises RateLimiter + Testnet. |
      ## Toolchain & check commands
      x
      ## Running tests
      x
      ## Do NOT edit
      x
      ## The trading domain layer
      ok
      """

      write!(root, "CLAUDE.md", claude)
      write!(root, "lib/bourse/signing.ex", "defmodule Bourse.Signing do\n  def sign(:custom, a, b, c), do: :ok\nend\n")

      write!(
        root,
        "lib/bourse/application.ex",
        """
        defmodule Bourse.Application do
          alias Bourse.WS.Broadcast

          def start(_type, _args) do
            children = [
              Bourse.RateLimiter,
              Bourse.Testnet,
              Bourse.Signing.Lighter.Supervisor,
              Broadcast.child_spec()
            ]

            Supervisor.start_link(children, strategy: :one_for_one)
          end
        end
        """
      )

      findings =
        ClaudeCheck.findings(
          Path.join(root, "CLAUDE.md"),
          root,
          Path.join(root, "lib/bourse/signing.ex"),
          Path.join(root, "lib/bourse/application.ex")
        )

      refs = Enum.map(findings, & &1.ref)
      assert "Bourse.Signing.Lighter.Supervisor" in refs
      assert "Bourse.WS.Broadcast" in refs
    end
  end

  describe "source parsers" do
    test "signing_patterns_from_source/1 reads literal def sign heads" do
      source = """
      # def sign(:commented_out, a, b, c), do: :ok
      def sign(:unsupported, a, b, c), do: :ok
      def sign(pattern, a, b, c) when is_atom(pattern), do: :ok
      def sign(
        :lighter,
        a,
        b,
        c
      ), do: :ok
      def sign(:custom, a, b, c), do: :ok
      """

      assert ClaudeCheck.signing_patterns_from_source(source) == ["custom", "lighter", "unsupported"]
    end

    test "application_children_from_source/1 resolves aliases and child_spec" do
      source = """
      defmodule Bourse.Application do
        alias Bourse.WS.Broadcast
        alias Bourse.Worker

        def start(_type, _args) do
          children = [
            Bourse.RateLimiter,
            Bourse.Signing.Lighter.Supervisor,
            Broadcast.child_spec(),
            {Worker, []}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end
      """

      assert ClaudeCheck.application_children_from_source(source) == [
               "Bourse.RateLimiter",
               "Bourse.Signing.Lighter.Supervisor",
               "Bourse.WS.Broadcast",
               "Bourse.Worker"
             ]
    end
  end

  describe "negated mix task mentions" do
    test "does not require a task that CLAUDE.md says does not exist" do
      root = temp_tree!()

      claude = """
      ### The workbench is dissolved
      x
      ### Venue authority index
      There is no `mix bourse.sync` task and no distill-resolution helper surface.
      ### Key modules
      | `Bourse.Signing` | routing 1 patterns. Patterns: `:custom`. Authoritative table lives in the module's `@moduledoc`. |
      | `Bourse.Application` | Supervises `Bourse.RateLimiter`. |
      ## Toolchain & check commands
      x
      ## Running tests
      x
      ## Do NOT edit
      x
      ## The trading domain layer
      ok
      """

      write!(root, "CLAUDE.md", claude)
      write!(root, "lib/bourse/rate_limiter.ex", "defmodule Bourse.RateLimiter do\nend\n")
      write!(root, "lib/bourse/signing.ex", "defmodule Bourse.Signing do\n  def sign(:custom, a, b, c), do: :ok\nend\n")

      write!(
        root,
        "lib/bourse/application.ex",
        """
        defmodule Bourse.Application do
          def start(_type, _args) do
            children = [Bourse.RateLimiter]
            Supervisor.start_link(children, strategy: :one_for_one)
          end
        end
        """
      )

      assert :ok =
               ClaudeCheck.check_paths!(
                 Path.join(root, "CLAUDE.md"),
                 root,
                 Path.join(root, "lib/bourse/signing.ex"),
                 Path.join(root, "lib/bourse/application.ex")
               )
    end
  end

  describe "CLI" do
    test "rejects positional arguments" do
      assert_raise Mix.Error, ~r/unexpected arguments: extra/, fn ->
        ClaudeCheck.run(["extra"])
      end
    end
  end

  describe "committed tree" do
    test "the real tree passes the gate" do
      assert :ok = ClaudeCheck.check_paths!("CLAUDE.md", ".")
    end
  end

  defp temp_tree! do
    path = Path.join(System.tmp_dir!(), "ccxt-claude-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp write!(root, rel, contents) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
