defmodule Bourse.TestnetTest do
  use Bourse.Test.Case, async: false

  alias Bourse.Testnet

  @moduletag trace_messages: true

  setup do
    Testnet.clear()
    :ok
  end

  describe "register/2,3" do
    test "registers credentials and returns :ok" do
      assert :ok = Testnet.register(:bybit, api_key: "k", secret: "s")
      assert %Bourse.Credentials{api_key: "k", secret: "s"} = Testnet.creds(:bybit)
    end

    test "returns :skipped when required fields are missing" do
      assert :skipped = Testnet.register(:bybit, api_key: "k")
      refute Testnet.registered?(:bybit)
    end

    test "raises on malformed credentials (wrong type)" do
      assert_raise ArgumentError, ~r/invalid credentials/, fn ->
        Testnet.register(:bybit, api_key: "k", secret: 123)
      end
    end

    test "raises on unknown keys" do
      assert_raise ArgumentError, ~r/invalid credentials/, fn ->
        Testnet.register(:bybit, api_key: "k", secret: "s", bogus: true)
      end
    end

    test "registers per-sandbox credentials" do
      assert :ok = Testnet.register(:binance, :default, api_key: "spot", secret: "s1")
      assert :ok = Testnet.register(:binance, :futures, api_key: "fut", secret: "s2")

      assert %{api_key: "spot"} = Testnet.creds(:binance)
      assert %{api_key: "fut"} = Testnet.creds(:binance, :futures)
    end

    test "sandbox_key of :default is the two-arg default" do
      assert :ok = Testnet.register(:kraken, api_key: "k", secret: "s")
      assert Testnet.registered?(:kraken, :default)
    end
  end

  describe "register_from_env/2,3" do
    test "reads testnet env vars with default sandbox" do
      System.put_env("FAKEFX_TESTNET_API_KEY", "ak")
      System.put_env("FAKEFX_TESTNET_API_SECRET", "sk")

      assert :ok = Testnet.register_from_env(:fakefx, testnet: true)
      assert %{api_key: "ak", secret: "sk", sandbox: true} = Testnet.creds(:fakefx)
    after
      System.delete_env("FAKEFX_TESTNET_API_KEY")
      System.delete_env("FAKEFX_TESTNET_API_SECRET")
    end

    test "reads sandbox-specific env vars (futures)" do
      System.put_env("FAKEFX_FUTURES_TESTNET_API_KEY", "fk")
      System.put_env("FAKEFX_FUTURES_TESTNET_API_SECRET", "fs")

      assert :ok = Testnet.register_from_env(:fakefx, :futures, testnet: true)
      assert %{api_key: "fk"} = Testnet.creds(:fakefx, :futures)
      refute Testnet.registered?(:fakefx, :default)
    after
      System.delete_env("FAKEFX_FUTURES_TESTNET_API_KEY")
      System.delete_env("FAKEFX_FUTURES_TESTNET_API_SECRET")
    end

    test "loads passphrase when requested" do
      System.put_env("FAKEFX_TESTNET_API_KEY", "ak")
      System.put_env("FAKEFX_TESTNET_API_SECRET", "sk")
      System.put_env("FAKEFX_PASSPHRASE", "pp")

      assert :ok = Testnet.register_from_env(:fakefx, testnet: true, passphrase: true)
      assert %{password: "pp"} = Testnet.creds(:fakefx)
    after
      System.delete_env("FAKEFX_TESTNET_API_KEY")
      System.delete_env("FAKEFX_TESTNET_API_SECRET")
      System.delete_env("FAKEFX_PASSPHRASE")
    end

    test "raises when passphrase is required but missing" do
      System.put_env("FAKEFX_TESTNET_API_KEY", "ak")
      System.put_env("FAKEFX_TESTNET_API_SECRET", "sk")
      System.delete_env("FAKEFX_PASSPHRASE")

      assert_raise ArgumentError, ~r/FAKEFX_PASSPHRASE is missing/, fn ->
        Testnet.register_from_env(:fakefx, testnet: true, passphrase: true)
      end
    after
      System.delete_env("FAKEFX_TESTNET_API_KEY")
      System.delete_env("FAKEFX_TESTNET_API_SECRET")
    end

    test "returns :skipped when env vars are not set" do
      System.delete_env("UNSET_TESTNET_API_KEY")
      System.delete_env("UNSET_TESTNET_API_SECRET")
      assert :skipped = Testnet.register_from_env(:unset, testnet: true)
    end

    test "accepts _TEST_ infix as a silent fallback when _TESTNET_ is unset" do
      System.delete_env("FAKEFX_FUTURES_TESTNET_API_KEY")
      System.delete_env("FAKEFX_FUTURES_TESTNET_API_SECRET")
      System.put_env("FAKEFX_FUTURES_TEST_API_KEY", "ak")
      System.put_env("FAKEFX_FUTURES_TEST_API_SECRET", "sk")

      assert :ok = Testnet.register_from_env(:fakefx, :futures, testnet: true)
      assert %{api_key: "ak", secret: "sk"} = Testnet.creds(:fakefx, :futures)
    after
      System.delete_env("FAKEFX_FUTURES_TEST_API_KEY")
      System.delete_env("FAKEFX_FUTURES_TEST_API_SECRET")
    end

    test "_TESTNET_ wins over _TEST_ when both are set" do
      System.put_env("FAKEFX_TESTNET_API_KEY", "canonical_key")
      System.put_env("FAKEFX_TESTNET_API_SECRET", "canonical_secret")
      System.put_env("FAKEFX_TEST_API_KEY", "alias_key")
      System.put_env("FAKEFX_TEST_API_SECRET", "alias_secret")

      assert :ok = Testnet.register_from_env(:fakefx, testnet: true)
      assert %{api_key: "canonical_key", secret: "canonical_secret"} = Testnet.creds(:fakefx)
    after
      System.delete_env("FAKEFX_TESTNET_API_KEY")
      System.delete_env("FAKEFX_TESTNET_API_SECRET")
      System.delete_env("FAKEFX_TEST_API_KEY")
      System.delete_env("FAKEFX_TEST_API_SECRET")
    end
  end

  describe "register_all_from_env/1" do
    test "registers the set of configs for which env vars exist" do
      System.put_env("AAA_TESTNET_API_KEY", "a")
      System.put_env("AAA_TESTNET_API_SECRET", "a")
      System.put_env("BBB_FUTURES_TESTNET_API_KEY", "b")
      System.put_env("BBB_FUTURES_TESTNET_API_SECRET", "b")

      registered =
        Testnet.register_all_from_env([
          {:aaa, testnet: true},
          {:bbb, :futures, testnet: true},
          {:ccc, testnet: true}
        ])

      assert {:aaa, :default} in registered
      assert {:bbb, :futures} in registered
      refute {:ccc, :default} in registered
      assert length(registered) == 2
    after
      Enum.each(
        ~w(AAA_TESTNET_API_KEY AAA_TESTNET_API_SECRET
         BBB_FUTURES_TESTNET_API_KEY BBB_FUTURES_TESTNET_API_SECRET),
        &System.delete_env/1
      )
    end
  end

  describe "creds!/2" do
    test "returns credentials when registered" do
      Testnet.register(:bybit, api_key: "k", secret: "s")
      assert %Bourse.Credentials{} = Testnet.creds!(:bybit)
    end

    test "raises with actionable env var names when unregistered" do
      assert_raise ArgumentError, ~r/BYBIT_TESTNET_API_KEY/, fn ->
        Testnet.creds!(:bybit)
      end
    end

    test "raises with sandbox-scoped env var names" do
      assert_raise ArgumentError, ~r/BINANCE_FUTURES_TESTNET_API_KEY/, fn ->
        Testnet.creds!(:binance, :futures)
      end
    end
  end

  describe "registered_exchanges/0 and exchanges_with_creds/0" do
    test "lists tuples and unique exchange atoms" do
      Testnet.register(:a, api_key: "k", secret: "s")
      Testnet.register(:b, :futures, api_key: "k", secret: "s")
      Testnet.register(:b, :coinm, api_key: "k", secret: "s")

      tuples = Testnet.registered_exchanges()
      assert {:a, :default} in tuples
      assert {:b, :futures} in tuples
      assert {:b, :coinm} in tuples

      assert Enum.sort(Testnet.exchanges_with_creds()) == [:a, :b]
    end
  end

  describe "unregister/2" do
    test "removes a single registration and leaves siblings intact" do
      Testnet.register(:b, :default, api_key: "k", secret: "s")
      Testnet.register(:b, :futures, api_key: "k", secret: "s")

      assert :ok = Testnet.unregister(:b, :default)

      refute Testnet.registered?(:b, :default)
      assert Testnet.registered?(:b, :futures)
    end

    test "defaults to the :default sandbox key" do
      Testnet.register(:b, api_key: "k", secret: "s")
      assert Testnet.registered?(:b, :default)

      assert :ok = Testnet.unregister(:b)
      refute Testnet.registered?(:b, :default)
    end

    test "is idempotent — unregistering an absent key returns :ok" do
      refute Testnet.registered?(:nope, :default)
      assert :ok = Testnet.unregister(:nope)
    end

    test "succeeds when called from a foreign process (protected table)" do
      Testnet.register(:b, api_key: "k", secret: "s")

      task = Task.async(fn -> Testnet.unregister(:b, :default) end)
      assert :ok = Task.await(task)
      refute Testnet.registered?(:b, :default)
    end
  end

  describe "sandbox_key_from_url/1" do
    test "detects futures via the current demo API path" do
      assert Testnet.sandbox_key_from_url("https://demo-fapi.binance.com/fapi/v1") ==
               :futures
    end

    test "detects coinm via the current demo API path" do
      assert Testnet.sandbox_key_from_url("https://demo-dapi.binance.com/dapi/v1") ==
               :coinm
    end

    test "retains legacy futures-host detection" do
      assert Testnet.sandbox_key_from_url("https://testnet.binancefuture.com/fapi/v1") ==
               :futures
    end

    test "defaults to :default for spot URLs and nil" do
      assert Testnet.sandbox_key_from_url("https://testnet.binance.vision/api/v3") == :default
      assert Testnet.sandbox_key_from_url(nil) == :default
    end
  end

  describe "env_var_prefix/2" do
    test "builds the expected prefix per sandbox" do
      assert Testnet.env_var_prefix(:binance, :default) == "BINANCE_TESTNET"
      assert Testnet.env_var_prefix(:binance, :futures) == "BINANCE_FUTURES_TESTNET"
      assert Testnet.env_var_prefix(:binance, :coinm) == "BINANCE_COINM_TESTNET"
      assert Testnet.env_var_prefix(:binance, :portfolio) == "BINANCE_PORTFOLIO_TESTNET"
    end
  end

  describe "registry table access" do
    test "table is :protected — reads stay open, foreign writes raise" do
      assert :ets.info(:bourse_testnet_registry, :protection) == :protected

      assert :ok = Testnet.register(:bybit, api_key: "k", secret: "s")

      # Reads from an arbitrary process keep working (lock-free read path).
      assert [{_key, %Bourse.Credentials{}}] = :ets.lookup(:bourse_testnet_registry, {:bybit, :default})

      # Direct writes from a non-owner process are rejected by ETS.
      assert_raise ArgumentError, fn ->
        :ets.insert(:bourse_testnet_registry, {{:bybit, :default}, :tampered})
      end

      # The registered entry is untouched after the rejected write.
      assert %Bourse.Credentials{api_key: "k"} = Testnet.creds(:bybit)
    end
  end
end
