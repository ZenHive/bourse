defmodule Mix.Tasks.Bourse.AgentsMdTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Bourse.AgentsMd

  describe "render/3" do
    test "inlines pinned external imports and leaves surrounding prose" do
      root = temp_tree!()

      write!(root, "includes/rules.md", "rule one\n")
      write!(root, "includes/unused.md", "unused\n")

      write!(root, "CLAUDE.md", """
      # Top
      @~/rules.md
      # Bottom
      """)

      # Unused pins are allowed; only imports referenced by CLAUDE.md are read.
      write_manifest!(root, %{
        "~/.claude/includes/unused.md" => "includes/unused.md",
        "~/rules.md" => "includes/rules.md"
      })

      assert {:ok, rendered} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert rendered =~ "<!-- Auto-generated from CLAUDE.md by mix bourse.agents_md"
      assert rendered =~ "<!-- @-import: ~/rules.md -->"
      assert rendered =~ "rule one"
      assert rendered =~ "# Top"
      assert rendered =~ "# Bottom"
      refute rendered =~ "@~/rules.md"
    end

    test "inlines repo-relative imports without a manifest pin" do
      root = temp_tree!()
      write!(root, "local.md", "local body\n")
      write!(root, "CLAUDE.md", "# Head\n@local.md\n")
      write_manifest!(root, %{})

      assert {:ok, rendered} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert rendered =~ "<!-- @-import: local.md -->"
      assert rendered =~ "local body"
    end
  end

  describe "check/4" do
    test "passes when AGENTS.md matches a fresh render" do
      root = fixture_tree!()

      assert :ok =
               AgentsMd.check(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "AGENTS.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )
    end

    test "fails when AGENTS.md has drifted" do
      root = fixture_tree!()
      agents = Path.join(root, "AGENTS.md")
      File.write!(agents, File.read!(agents) <> "\n# tampered\n")

      assert {:error, reason} =
               AgentsMd.check(
                 Path.join(root, "CLAUDE.md"),
                 agents,
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "STALE"
      assert reason =~ "drifted"
      assert reason =~ "mix bourse.agents_md"
    end

    test "fails when AGENTS.md is missing" do
      root = fixture_tree!()
      agents = Path.join(root, "AGENTS.md")
      File.rm!(agents)

      assert {:error, reason} =
               AgentsMd.check(
                 Path.join(root, "CLAUDE.md"),
                 agents,
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "STALE"
      assert reason =~ "missing"
    end
  end

  describe "missing / unpinned sources" do
    test "undeclared external import fails naming the source" do
      root = temp_tree!()
      write!(root, "CLAUDE.md", "@~/secret-rules.md\n")
      write_manifest!(root, %{})

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "~/secret-rules.md"
      assert reason =~ "undeclared external"
      assert reason =~ "never falls back"
    end

    test "declared pin whose file is absent fails naming the source" do
      root = temp_tree!()
      write!(root, "CLAUDE.md", "@~/rules.md\n")
      write_manifest!(root, %{"~/rules.md" => "includes/rules.md"})
      # deliberately do not write includes/rules.md

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "~/rules.md"
      assert reason =~ "cannot read @-import"
    end

    test "pin hash mismatch fails naming the source" do
      root = temp_tree!()
      write!(root, "CLAUDE.md", "@~/rules.md\n")
      write!(root, "includes/rules.md", "fresh content\n")

      manifest = %{
        "schema_version" => 1,
        "max_depth" => 5,
        "includes" => %{
          "~/rules.md" => %{
            "path" => "includes/rules.md",
            "sha256" => String.duplicate("0", 64),
            "bytes" => 14
          }
        }
      }

      File.mkdir_p!(Path.join(root, "priv/agents_includes"))
      File.write!(Path.join(root, "priv/agents_includes/manifest.json"), Jason.encode!(manifest))

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "~/rules.md"
      assert reason =~ "hash mismatch"
    end

    test "missing repo-relative import fails naming the source" do
      root = temp_tree!()
      write!(root, "CLAUDE.md", "@missing-local.md\n")
      write_manifest!(root, %{})

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "missing-local.md"
      assert reason =~ "cannot read @-import"
    end

    test "missing manifest fails naming the manifest path" do
      root = temp_tree!()
      write!(root, "CLAUDE.md", "# only\n")

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "include manifest"
      assert reason =~ "not found"
    end

    test "manifest requires an includes object" do
      root = temp_tree!()
      write!(root, "CLAUDE.md", "# only\n")
      write_manifest_payload!(root, %{"schema_version" => 1})

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "missing an object"
      assert reason =~ "\"includes\""
    end

    test "manifest must be a valid JSON object" do
      root = temp_tree!()
      write!(root, "CLAUDE.md", "# only\n")
      write!(root, "priv/agents_includes/manifest.json", "[not-json")

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "not valid JSON"
    end

    test "manifest rejects valid JSON that is not an object" do
      root = temp_tree!()
      write!(root, "CLAUDE.md", "# only\n")
      write!(root, "priv/agents_includes/manifest.json", "[]")

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "must be a JSON object"
    end

    test "repo-relative import cannot escape the repository root" do
      root = temp_tree!()
      outside = root <> "-outside.md"
      on_exit(fn -> File.rm(outside) end)
      File.write!(outside, "operator-local rules\n")
      write!(root, "CLAUDE.md", "@../#{Path.basename(outside)}\n")
      write_manifest!(root, %{})

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ Path.basename(outside)
      assert reason =~ "outside repository root"
    end

    test "external include pin must use a repository-relative path" do
      root = temp_tree!()
      outside = root <> "-outside.md"
      on_exit(fn -> File.rm(outside) end)
      File.write!(outside, "operator-local rules\n")
      write!(root, "CLAUDE.md", "@~/rules.md\n")

      write_manifest_payload!(root, %{
        "schema_version" => 1,
        "max_depth" => 5,
        "includes" => %{
          "~/rules.md" => %{
            "path" => outside,
            "sha256" => sha256("operator-local rules\n"),
            "bytes" => byte_size("operator-local rules\n")
          }
        }
      })

      assert {:error, reason} =
               AgentsMd.render(
                 Path.join(root, "CLAUDE.md"),
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert reason =~ "~/rules.md"
      assert reason =~ "repository-relative"
    end
  end

  describe "write!/4 and check!/4" do
    test "write regenerates AGENTS.md so a subsequent check passes" do
      root = fixture_tree!()
      agents = Path.join(root, "AGENTS.md")
      File.write!(agents, "stale\n")

      assert :ok =
               AgentsMd.write!(
                 Path.join(root, "CLAUDE.md"),
                 agents,
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )

      assert :ok =
               AgentsMd.check!(
                 Path.join(root, "CLAUDE.md"),
                 agents,
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 root
               )
    end

    test "check! raises Mix.Error on drift" do
      root = fixture_tree!()
      agents = Path.join(root, "AGENTS.md")
      File.write!(agents, "stale\n")

      error =
        assert_raise Mix.Error, fn ->
          AgentsMd.check!(
            Path.join(root, "CLAUDE.md"),
            agents,
            Path.join(root, "priv/agents_includes/manifest.json"),
            root
          )
        end

      assert error.message =~ "STALE"
    end
  end

  describe "run/1" do
    test "CLI check mode validates explicit checkout paths" do
      root = fixture_tree!()

      assert :ok =
               AgentsMd.run([
                 "--check",
                 "--claude",
                 Path.join(root, "CLAUDE.md"),
                 "--agents",
                 Path.join(root, "AGENTS.md"),
                 "--manifest",
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 "--root",
                 root
               ])
    end

    test "CLI dry-run mode renders without changing AGENTS.md" do
      root = fixture_tree!()
      agents = Path.join(root, "AGENTS.md")
      original = File.read!(agents)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   AgentsMd.run([
                     "--dry-run",
                     "--claude",
                     Path.join(root, "CLAUDE.md"),
                     "--agents",
                     agents,
                     "--manifest",
                     Path.join(root, "priv/agents_includes/manifest.json"),
                     "--root",
                     root
                   ])
        end)

      assert output =~ "Auto-generated from CLAUDE.md"
      assert File.read!(agents) == original
    end

    test "CLI write mode regenerates AGENTS.md" do
      root = fixture_tree!()
      agents = Path.join(root, "AGENTS.md")
      File.write!(agents, "stale\n")

      assert :ok =
               AgentsMd.run([
                 "--claude",
                 Path.join(root, "CLAUDE.md"),
                 "--agents",
                 agents,
                 "--manifest",
                 Path.join(root, "priv/agents_includes/manifest.json"),
                 "--root",
                 root
               ])

      assert File.read!(agents) =~ "pinned rule body"
    end
  end

  describe "repository checkout" do
    test "the committed tree is currently fresh" do
      assert :ok = AgentsMd.check("CLAUDE.md", "AGENTS.md", "priv/agents_includes/manifest.json", ".")
    end
  end

  defp fixture_tree! do
    root = temp_tree!()
    write!(root, "includes/rules.md", "pinned rule body\n")

    write!(root, "CLAUDE.md", """
    # Fixture CLAUDE
    @~/rules.md
    ## After include
    """)

    write_manifest!(root, %{"~/rules.md" => "includes/rules.md"})

    {:ok, rendered} =
      AgentsMd.render(
        Path.join(root, "CLAUDE.md"),
        Path.join(root, "priv/agents_includes/manifest.json"),
        root
      )

    write!(root, "AGENTS.md", rendered)
    root
  end

  defp write_manifest!(root, includes_map) do
    includes =
      Map.new(includes_map, fn {declared, rel} ->
        abs = Path.join(root, rel)

        case File.read(abs) do
          {:ok, body} ->
            {declared, %{"path" => rel, "sha256" => sha256(body), "bytes" => byte_size(body)}}

          {:error, :enoent} ->
            # Negative tests may declare a pin before the file exists.
            {declared, %{"path" => rel, "sha256" => sha256(""), "bytes" => 0}}
        end
      end)

    payload = %{
      "schema_version" => 1,
      "max_depth" => 5,
      "includes" => includes
    }

    write_manifest_payload!(root, payload)
    root
  end

  defp write_manifest_payload!(root, payload) do
    File.mkdir_p!(Path.join(root, "priv/agents_includes"))
    File.write!(Path.join(root, "priv/agents_includes/manifest.json"), Jason.encode!(payload))
  end

  defp temp_tree! do
    root =
      Path.join(
        System.tmp_dir!(),
        "ccxt-agents-md-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp write!(root, rel, contents) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp sha256(contents) do
    :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
  end
end
