defmodule Mix.Tasks.Ccxt.PromoteVenueTest do
  use ExUnit.Case, async: false

  alias Bourse.Spec.Promotion
  alias Mix.Tasks.Ccxt.PromoteVenue

  @reference_path "priv/specs/json/output/bybit.json"

  setup do
    root = Path.join(System.tmp_dir!(), "ccxt-promotion-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "prepare writes candidate and report without writing runtime support", %{root: root} do
    candidate = Path.join(root, "candidate.json")
    report = Path.join(root, "evidence.json")
    authored = Path.join(root, "authored.json")

    reenable_and_run([
      "--prepare",
      "--reference",
      @reference_path,
      "--candidate",
      candidate,
      "--report",
      report
    ])

    assert %{"authored" => false, "hand_owned" => false, "frozen" => false} = Bourse.Spec.decode_file!(candidate)
    assert %{"status" => "candidate", "gaps" => gaps} = Bourse.Spec.decode_file!(report)
    assert gaps != []
    refute File.exists?(authored)
  end

  test "prepare refuses to overwrite its artifacts without force", %{root: root} do
    candidate = Path.join(root, "candidate.json")
    report = Path.join(root, "evidence.json")
    File.write!(candidate, "existing")

    assert_raise Mix.Error, ~r/refusing to overwrite/, fn ->
      reenable_and_run([
        "--prepare",
        "--reference",
        @reference_path,
        "--candidate",
        candidate,
        "--report",
        report
      ])
    end

    assert :ok =
             reenable_and_run([
               "--prepare",
               "--force",
               "--reference",
               @reference_path,
               "--candidate",
               candidate,
               "--report",
               report
             ])

    assert Bourse.Spec.decode_file!(candidate)["authored"] == false
  end

  test "check fails loudly with the complete gap report", %{root: root} do
    candidate = Path.join(root, "candidate.json")
    report = Path.join(root, "evidence.json")

    reenable_and_run([
      "--prepare",
      "--reference",
      @reference_path,
      "--candidate",
      candidate,
      "--report",
      report
    ])

    assert_raise Mix.Error, ~r/promotion refused:.*schema_invalid/s, fn ->
      reenable_and_run(["--check", "--candidate", candidate, "--report", report])
    end
  end

  test "check accepts an explicit --reference pin and refuses digest mismatch", %{root: root} do
    candidate = Path.join(root, "candidate.json")
    report_path = Path.join(root, "evidence.json")

    reenable_and_run([
      "--prepare",
      "--reference",
      @reference_path,
      "--candidate",
      candidate,
      "--report",
      report_path
    ])

    report = Bourse.Spec.decode_file!(report_path)
    report = put_in(report, ["reference", "sha256"], String.duplicate("a", 64))
    File.write!(report_path, Promotion.encode!(report))

    assert_raise Mix.Error, ~r/reference_digest_mismatch/, fn ->
      reenable_and_run([
        "--check",
        "--candidate",
        candidate,
        "--report",
        report_path,
        "--reference",
        @reference_path
      ])
    end
  end

  test "promote refuses an incomplete candidate without writing output", %{root: root} do
    candidate = Path.join(root, "candidate.json")
    report = Path.join(root, "evidence.json")
    output = Path.join(root, "owned.json")

    reenable_and_run([
      "--prepare",
      "--reference",
      @reference_path,
      "--candidate",
      candidate,
      "--report",
      report
    ])

    assert_raise Mix.Error, ~r/promotion refused/, fn ->
      reenable_and_run([
        "--promote",
        output,
        "--candidate",
        candidate,
        "--report",
        report
      ])
    end

    refute File.exists?(output)
  end

  test "invalid modes and positional arguments fail loudly" do
    assert_raise Mix.Error, ~r/select exactly one/, fn -> reenable_and_run([]) end
    assert_raise Mix.Error, ~r/unexpected arguments/, fn -> reenable_and_run(["unexpected"]) end
  end

  defp reenable_and_run(args) do
    Mix.Task.reenable("ccxt.promote_venue")
    PromoteVenue.run(args)
  end
end
