defmodule Bourse.MixProjectTest do
  use ExUnit.Case, async: true

  alias Bourse.Registry

  @source_url "https://github.com/ZenHive/bourse"
  # native/lighter_signer ships the Go/C signer sources so consumers can build
  # the Lighter helper themselves; the compiled binary is never packaged.
  @runtime_venues ~w(alpaca binance binancecoinm binanceusdm bybit deribit derive hyperliquid lighter okx)
  # The trading domain is developed here but is not part of the client's surface,
  # so `lib/bourse` ships enumerated rather than as a blanket directory entry.
  @domain_prefixes ~w(option_proposal option_readiness option_saga portfolio_risk)
  @expected_non_lib ~w(lib/bourse.ex lib/mix/tasks/ccxt.build_lighter_signer.ex) ++
                      ~w(native/lighter_signer mix.exs README.md LICENSE) ++
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
      assert lib_bourse == Enum.reject(Path.wildcard("lib/bourse/**"), &domain_path?/1)
      assert lib_bourse != []

      # The domain layer stays out of the tarball; the client half ships whole.
      refute Enum.any?(files, &domain_path?/1)
      assert Enum.all?(Path.wildcard("lib/bourse/**"), &(&1 in files or domain_path?(&1)))

      refute Enum.any?(files, &String.starts_with?(&1, "priv/specs/json/ccxt"))
      refute "priv/specs/json/reference_corpus.json" in files
      refute "priv/specs/json/output" in files
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

  defp domain_path?(path) do
    rest = Path.relative_to(path, "lib/bourse")
    Enum.any?(@domain_prefixes, &(rest == "#{&1}.ex" or String.starts_with?(rest, "#{&1}/")))
  end
end
