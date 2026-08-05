defmodule Bourse.MixProjectTest do
  use ExUnit.Case, async: true

  alias Bourse.Registry

  @source_url "https://github.com/ZenHive/bourse"
  # native/lighter_signer ships the Go/C signer sources so consumers can build
  # the Lighter helper themselves; the compiled binary is never packaged.
  @runtime_venues ~w(alpaca binance binancecoinm binanceusdm bybit deribit derive hyperliquid lighter okx)
  # The trading domain and the venue-promotion tooling are developed here but are
  # not part of the client's surface, so `lib/bourse` ships enumerated rather
  # than as a blanket directory entry.
  @domain_prefixes ~w(option_proposal option_readiness option_saga portfolio_risk)
  @unpackaged_prefixes @domain_prefixes ++ ~w(spec/promotion)
  @expected_non_lib ~w(lib/bourse.ex lib/mix/tasks/ccxt.build_lighter_signer.ex) ++
                      ~w(native/lighter_signer mix.exs README.md LICENSE NOTICE) ++
                      ["priv/specs/json/runtime_support.json"] ++
                      Enum.map(@runtime_venues, &"priv/specs/json/output/authored/#{&1}.json")

  describe "hex package metadata" do
    test "mix.exs exposes MIT license, source_url, and description" do
      config = Mix.Project.config()

      assert config[:app] == :bourse
      assert config[:source_url] == @source_url
      assert config[:homepage_url] == @source_url
      assert config[:version] == "0.1.0"
      assert is_binary(config[:description])
      assert config[:description] != ""

      package = Keyword.fetch!(config, :package)
      assert package[:licenses] == ["MIT"]
      assert package[:links]["GitHub"] == @source_url
      files = package[:files]
      {lib_bourse, rest} = Enum.split_with(files, &String.starts_with?(&1, "lib/bourse/"))

      assert rest == @expected_non_lib
      assert lib_bourse != []

      # The domain layer and the promotion tooling stay out of the tarball; the
      # client half ships whole.
      refute Enum.any?(files, &unpackaged_path?/1)
      assert Enum.all?(Path.wildcard("lib/bourse/**/*.ex"), &(&1 in files or unpackaged_path?(&1)))

      for excluded <- @unpackaged_prefixes do
        refute Enum.any?(files, &String.starts_with?(&1, "lib/bourse/#{excluded}"))
      end

      refute Enum.any?(files, &String.starts_with?(&1, "priv/specs/json/ccxt"))
      refute "priv/specs/json/reference_corpus.json" in files
      refute "priv/specs/json/output" in files
    end

    # Hex expands a listed directory recursively, so a directory entry ships the
    # subtree beneath it no matter what the prefix list excludes: `option_saga`
    # did it at depth 1, and `lib/bourse/spec` — relative path "spec", matching no
    # prefix — did it again at depth 2 for `spec/promotion/**`. A prefix assertion
    # cannot see either, because the directory entry is *shorter* than the prefix
    # it smuggles in. This is the invariant that removes the class.
    test "no lib entry is a directory Hex would expand" do
      files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

      lib_dirs = Enum.filter(files, &(String.starts_with?(&1, "lib/") and File.dir?(&1)))

      assert lib_dirs == []
    end

    test "only the consumer-facing Lighter build task ships" do
      files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

      # A blanket `lib` entry would sweep in repo-internal tooling that reads
      # unpackaged paths (test/fixtures, roadmap/, CLAUDE.md, the CCXT reference
      # corpus), giving consumers `mix help` entries that fail on a missing file.
      refute "lib" in files

      shipped_tasks =
        Enum.filter(files, &String.starts_with?(&1, "lib/mix"))

      assert shipped_tasks == ["lib/mix/tasks/ccxt.build_lighter_signer.ex"]

      # Every other task stays in the repo, so the tree must still hold them.
      assert length(Path.wildcard("lib/mix/tasks/**/*.ex")) > 1
    end

    test "LICENSE file is MIT" do
      license = File.read!("LICENSE")

      assert String.starts_with?(license, "MIT License")
      assert license =~ "Permission is hereby granted"
    end

    test "NOTICE attributes the CCXT text the authored specs still carry" do
      notice = File.read!("NOTICE")

      # The shipped authored specs retain CCXT's own method/return descriptions,
      # `{@link https://docs.ccxt.com/…}` references included. CCXT is MIT, whose
      # terms require the copyright notice to travel with that text.
      assert notice =~ "Copyright © 2024 Igor Kroitor"
      assert notice =~ "Permission is hereby granted"
      assert notice =~ "https://github.com/ccxt/ccxt"

      shipped_specs = Path.wildcard("priv/specs/json/output/authored/*.json")
      assert shipped_specs != []

      carries_ccxt_text? =
        Enum.any?(shipped_specs, &(&1 |> File.read!() |> String.contains?("docs.ccxt.com")))

      # If the projection is ever fully re-authored the notice may go — but only
      # then, and deliberately. While the text ships, so must the attribution.
      assert carries_ccxt_text?,
             "no shipped spec references docs.ccxt.com any more — re-check whether NOTICE's CCXT section is still required"
    end

    @tag :package
    test "the built tarball ships no excluded module" do
      out = Path.join(System.tmp_dir!(), "bourse-package-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(out) end)

      {output, status} =
        System.cmd("mix", ["hex.build", "--unpack", "--output", out],
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "dev"}]
        )

      assert status == 0, "mix hex.build failed:\n#{output}"

      shipped =
        out
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.reject(&File.dir?/1)
        |> Enum.map(&Path.relative_to(&1, out))

      assert "lib/bourse.ex" in shipped
      assert "NOTICE" in shipped

      # Asserting on the real artifact is the point: `package[:files]` looked
      # correct while Hex's directory expansion shipped `spec/promotion/**`
      # anyway, and every predicate-level assertion agreed with the bug.
      for excluded <- @unpackaged_prefixes do
        offenders = Enum.filter(shipped, &String.starts_with?(&1, "lib/bourse/#{excluded}"))
        assert offenders == [], "tarball ships excluded #{excluded}: #{inspect(offenders)}"
      end
    end
  end

  describe "ExDoc configuration" do
    test "docs config enables markdown output and llms.txt metadata" do
      config = Mix.Project.config()
      docs = Keyword.fetch!(config, :docs)

      assert Keyword.fetch!(docs, :main) == "readme"
      assert is_binary(Keyword.fetch!(docs, :description))
      assert Keyword.fetch!(docs, :description) != ""

      extras = Keyword.fetch!(docs, :extras)
      assert "README.md" in extras
      assert "CHANGELOG.md" in extras
      assert "CONTRIBUTING.md" in extras
    end
  end

  describe "security checks" do
    test "Sobelow fails the command for low-severity findings" do
      config = ".sobelow-conf" |> File.read!() |> Code.string_to_quoted!()

      assert {settings, []} = Code.eval_quoted(config)
      assert Keyword.fetch!(settings, :exit) == "low"
    end
  end

  describe "README exchange list" do
    test "README documents the Lighter native build prerequisite" do
      readme = File.read!("README.md")

      assert readme =~ "Go 1.23.1"
      assert readme =~ "mix ccxt.build_lighter_signer"
      assert readme =~ "prebuilt native binaries"
    end

    test "README first-class table lists exactly the curated venues" do
      readme = File.read!("README.md")
      table_ids = extract_readme_exchange_ids(readme)

      assert Enum.sort(table_ids) == Enum.sort(@runtime_venues)
    end

    test "every README-listed first-class venue is actually compiled" do
      compiled = MapSet.new(Registry.exchanges())

      for exchange_id <- @runtime_venues do
        assert MapSet.member?(compiled, exchange_id),
               "README documents first-class venue #{exchange_id} but it is not in Registry.exchanges/0"
      end
    end
  end

  defp extract_readme_exchange_ids(readme) do
    readme
    |> String.split("## Supported Exchanges")
    |> Enum.at(1, "")
    |> String.split("##", parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| `"))
    |> Enum.map(fn line ->
      line
      |> String.trim_leading("| `")
      |> String.split("`", parts: 2)
      |> hd()
    end)
  end

  # Hex packages a listed directory recursively, so the bare directory entry
  # `Path.wildcard/1` returns must be excluded alongside the files under it.
  defp unpackaged_path?(path) do
    rest = Path.relative_to(path, "lib/bourse")

    Enum.any?(
      @unpackaged_prefixes,
      &(rest in [&1, "#{&1}.ex"] or String.starts_with?(rest, "#{&1}/"))
    )
  end
end
