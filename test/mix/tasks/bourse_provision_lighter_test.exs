defmodule Mix.Tasks.Bourse.ProvisionLighterTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Bourse.ProvisionLighter

  @l1_vars ~w(LIGHTER_TESTNET_L1_ADDRESS LIGHTER_TESTNET_L1_PRIVATE_KEY)
  @api_vars ~w(LIGHTER_TESTNET_API_PRIVATE_KEY LIGHTER_TESTNET_API_KEY_INDEX)

  setup do
    saved = Map.new(@l1_vars ++ @api_vars, &{&1, System.get_env(&1)})
    Enum.each(@l1_vars ++ @api_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "missing L1 key fails loudly with flags and env vars" do
    error =
      assert_raise Mix.Error, fn ->
        ProvisionLighter.run([])
      end

    assert error.message =~ "--l1-address"
    assert error.message =~ "--l1-private-key"
    assert error.message =~ "LIGHTER_TESTNET_L1_ADDRESS"
    assert error.message =~ "LIGHTER_TESTNET_L1_PRIVATE_KEY"
    assert error.message =~ "Bourse.Credentials"
  end

  test "missing zk API key fails loudly after L1 flags are supplied" do
    error =
      assert_raise Mix.Error, fn ->
        ProvisionLighter.run([
          "--l1-address",
          "0x" <> String.duplicate("11", 20),
          "--l1-private-key",
          "0x" <> String.duplicate("22", 32)
        ])
      end

    assert error.message =~ "--api-private-key"
    assert error.message =~ "--api-key-index"
    assert error.message =~ "LIGHTER_TESTNET_API_PRIVATE_KEY"
  end

  test "invalid flags fail loudly" do
    error =
      assert_raise Mix.Error, fn ->
        ProvisionLighter.run(["--not-a-flag"])
      end

    assert error.message =~ "Invalid options"
  end
end
