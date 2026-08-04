defmodule Mix.Tasks.Ccxt.OracleGateTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ccxt.OracleGate

  test "task reports binary slots, critical gaps, and the exact-set ratchet" do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)

    assert :ok = OracleGate.run([])
    messages = collect_messages([])

    for venue <- Bourse.Spec.exchanges() do
      assert Enum.any?(messages, &String.starts_with?(&1, "#{venue}: verified"))
    end

    assert Enum.any?(messages, &String.contains?(&1, "verified auth.sign_recipe.private"))
    assert Enum.any?(messages, &String.contains?(&1, "critical=true missing_methods="))
    assert Enum.any?(messages, &String.contains?(&1, "verification=recorded_error"))
    assert Enum.any?(messages, &String.contains?(&1, "verification=provider_doc"))
    assert "binary oracle exact-set ratchet passed" in messages
  end

  test "task rejects unsupported arguments" do
    assert_raise Mix.Error, ~r/usage: mix ccxt.oracle_gate/, fn ->
      OracleGate.run(["--unknown"])
    end
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
