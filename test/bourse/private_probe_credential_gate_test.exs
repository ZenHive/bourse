defmodule Bourse.PrivateProbeCredentialGateTest do
  use ExUnit.Case, async: false

  alias Bourse.Test.Generator.RawEndpointProbe
  alias Bourse.Test.TestnetSnapshot
  alias Bourse.Testnet

  setup do
    # Restore whatever test_helper.exs registered, not a hand-listed subset:
    # the previous on_exit put back four venues and left the other seven
    # unregistered for the rest of the run. See Bourse.Test.TestnetSnapshot.
    snapshot = TestnetSnapshot.capture()
    on_exit(fn -> TestnetSnapshot.restore(snapshot) end)

    Testnet.clear()
    :ok
  end

  describe "credential-gated private probe emission" do
    test "raw private modules without registered credentials emit one flunk test and no setup_all" do
      test_module = build_probe_module(:RawPrivateUnregistered, RawEndpointProbe, :coinbaseexchange, :private)

      assert %{setup_all?: false, tests: [test]} = test_module.__ex_unit__()
      assert test.tags.private
      assert test.tags.network
      assert test.tags.raw
      assert test.tags.exchange_coinbaseexchange
      assert_missing_credentials_test(test_module, test, :coinbaseexchange)
    end

    test "raw private_dangerous modules without registered credentials emit one flunk test and no setup_all" do
      test_module =
        build_probe_module(:RawPrivateDangerousUnregistered, RawEndpointProbe, :coinbaseexchange, :private_dangerous)

      assert %{setup_all?: false, tests: [test]} = test_module.__ex_unit__()
      assert test.tags.private
      assert test.tags.dangerous
      assert test.tags.network
      assert test.tags.raw
      assert test.tags.exchange_coinbaseexchange
      assert_missing_credentials_test(test_module, test, :coinbaseexchange)
    end

    test "registered exchanges keep raw per-endpoint tests and runtime setup_all backstop" do
      Testnet.register(:bybit, api_key: "key", secret: "secret")

      test_module = build_probe_module(:RawRegistered, RawEndpointProbe, :bybit, :private)

      assert %{setup_all?: true, tests: tests} = test_module.__ex_unit__()
      assert length(tests) > 1
      assert Enum.all?(tests, & &1.tags.private)
    end
  end

  defp build_probe_module(suffix, generator, exchange, auth) do
    unique_suffix = :"#{suffix}#{System.unique_integer([:positive])}"
    module_name = Module.concat([__MODULE__, unique_suffix])

    Module.create(
      module_name,
      quote do
        use ExUnit.Case, async: false
        use unquote(generator), exchange: unquote(exchange), auth: unquote(auth)
      end,
      Macro.Env.location(__ENV__)
    )

    module_name
  end

  defp assert_missing_credentials_test(module, test, exchange) do
    prefix = exchange |> Atom.to_string() |> String.upcase()

    assert_raise ExUnit.AssertionError, ~r/Missing testnet credentials.*#{prefix}_TESTNET_API_KEY/s, fn ->
      apply(module, test.name, [%{}])
    end
  end
end
