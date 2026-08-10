defmodule Mix.Tasks.Ccxt.OracleGateTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.OracleGate

  test "task reports binary slots, per-venue hard passes, and the exact-set ratchet" do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    assert :ok = OracleGate.run([])
    messages = collect_messages([])

    for venue <- Bourse.Spec.exchanges() do
      assert Enum.any?(messages, &String.starts_with?(&1, "#{venue}: verified"))
    end

    assert Enum.any?(messages, &String.contains?(&1, "verified auth.sign_recipe.private"))

    assert Enum.count(messages, &String.contains?(&1, "critical-slot hard gate passed")) ==
             length(Bourse.Spec.exchanges())

    assert Enum.any?(messages, &String.contains?(&1, "verification=recorded_error"))
    assert Enum.any?(messages, &String.contains?(&1, "verification=provider_doc"))
    assert "binary oracle exact-set ratchet passed" in messages
  end

  test "task rejects unsupported arguments" do
    assert_raise Mix.Error, ~r/usage: mix ccxt.oracle_gate/, fn ->
      OracleGate.run(["--unknown"])
    end
  end

  test "task rejects an expired critical-slot waiver with its renewal path" do
    error =
      assert_raise Mix.Error, fn ->
        OracleGate.run([], today: ~D[2026-09-10])
      end

    assert error.message =~ "alpaca:normalization.field_maps.position waiver review expired after 30 days"
    assert error.message =~ "[oracle-critical-slot-waiver-review YYYY-MM-DD]"
    assert error.message =~ "docs/prod-verification-ledger.md"
  end

  test "task declares the test environment" do
    preferred_envs = Bourse.MixProject.cli()[:preferred_envs]
    assert preferred_envs[:"ccxt.oracle_gate"] == :test
  end

  defp collect_messages(messages) do
    receive do
      {:mix_shell, :info, [message]} -> collect_messages([IO.iodata_to_binary(message) | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end
end
