defmodule Bourse.IntegrationSandboxGateTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Bourse.Exchange
  alias Bourse.IntegrationHelper

  @tag :integration
  test "registered creds without testnet spec fail sandbox gate, not production URLs" do
    :ok = Bourse.Testnet.register(:aster, :default, api_key: "k", secret: "s", sandbox: true)
    assert Bourse.Testnet.registered?(:aster)

    assert {:error, :no_testnet_data} = Exchange.new(:aster, sandbox: true)

    assert_raise ArgumentError, ~r/no testnet data/, fn ->
      IntegrationHelper.build_exchange(:aster,
        credentials: Bourse.Testnet.creds(:aster),
        sandbox: true
      )
    end
  end
end
