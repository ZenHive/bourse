defmodule Bourse.Test.Generator.UnifiedWriteMethodIntegrationProbe do
  @moduledoc """
  Compile-time generator for dangerous unified write-method integration probes.

  These tests are deliberately gated by both `:network` and `:dangerous`.
  A test never invents assets: `Bourse.Test.AssetConfig` must provide the
  `{exchange_id, method}` entry, and each order lifecycle creates and cancels
  the order in the same test body.
  """

  import ExUnit.Assertions

  alias Bourse.Error, as: CError
  alias Bourse.Registry
  alias Bourse.Test.AssetConfig

  @auth_classes [:private_dangerous]
  @custom_supported_patterns [:derive, :hyperliquid]

  defmacro __using__(opts) do
    exchange = Keyword.fetch!(opts, :exchange)
    auth = Keyword.get(opts, :auth, :private_dangerous)

    if auth not in @auth_classes do
      raise ArgumentError,
            "UnifiedWriteMethodIntegrationProbe: auth must be one of #{inspect(@auth_classes)}, got #{inspect(auth)}"
    end

    exchange_id = to_string(exchange)
    exchange_atom = String.to_atom(exchange_id)

    test_blocks =
      for {kind, ^exchange_id, method} <- cases_for(exchange_id, auth) do
        build_test(kind, exchange_id, exchange_atom, method)
      end

    quote do
      @moduletag :network
      @moduletag :dangerous
      @moduletag :unified_integration
      @moduletag unquote(String.to_atom("exchange_#{exchange_id}"))

      unquote(build_setup_gate(exchange_id, exchange_atom))
      unquote_splicing(test_blocks)
    end
  end

  @doc "Collects dangerous write-method cases selected at compile time."
  @spec __collect_for_inspection__() :: [{:private_dangerous, String.t(), AssetConfig.write_method()}]
  def __collect_for_inspection__ do
    Enum.flat_map(Registry.exchanges(), &cases_for(&1, :private_dangerous))
  end

  @doc "Fetches a dangerous asset config or flunks with setup instructions."
  @spec __fetch_config!(atom(), AssetConfig.write_method()) :: AssetConfig.t()
  def __fetch_config!(exchange, method) do
    case AssetConfig.fetch(exchange, method) do
      {:ok, config} ->
        config

      {:error, {:missing_asset_config, exchange_id, method}} ->
        flunk("""
        Missing dangerous asset config for #{exchange_id} #{method}.

        Add a Bourse.Test.AssetConfig entry keyed by #{inspect({exchange_id, method})}
        with symbol/size/safety_flags/cleanup before running this probe.
        """)
    end
  end

  @doc "Asserts a dangerous probe is running against a sandbox exchange."
  @spec __ensure_testnet!(Bourse.Exchange.t(), AssetConfig.write_method()) :: :ok
  def __ensure_testnet!(%Bourse.Exchange{sandbox: true}, _method), do: :ok

  def __ensure_testnet!(%Bourse.Exchange{id: id, sandbox: sandbox}, method) do
    flunk("""
    #{id} #{method}: dangerous probe requires sandbox resolution.
    Expected exchange.sandbox == true, got #{inspect(sandbox)}.
    """)
  end

  @doc "Runs one dangerous write-method lifecycle."
  @spec __run_write_case__(AssetConfig.write_method(), Bourse.Exchange.t(), AssetConfig.t(), keyword()) :: :ok
  def __run_write_case__(method, exchange, %AssetConfig{} = config, opts \\ []) do
    __ensure_testnet!(exchange, method)

    api_module = Keyword.get(opts, :api_module, Bourse)
    run_write_case(method, exchange, config, api_module)
  end

  @doc "Flunks unless both dangerous probe include flags are present."
  @spec __require_explicit_includes!() :: :ok
  def __require_explicit_includes! do
    include = Keyword.get(ExUnit.configuration(), :include, [])

    if __explicit_include_tags?(include) do
      :ok
    else
      flunk("""
      Dangerous unified write probes require both flags:
        mix test.json --include network --include dangerous
      """)
    end
  end

  @doc "Returns true when both `:network` and `:dangerous` are explicitly included."
  @spec __explicit_include_tags?(keyword() | [atom()]) :: boolean()
  def __explicit_include_tags?(include) when is_list(include) do
    included?(include, :network) and included?(include, :dangerous)
  end

  defp cases_for(exchange_id, :private_dangerous) do
    module = Registry.module_for(exchange_id)

    if module && signing_supported?(module) do
      for method <- AssetConfig.methods(), available_private?(module, method) do
        {:private_dangerous, exchange_id, method}
      end
    else
      []
    end
  end

  defp signing_supported?(module) do
    case signing_pattern(module) do
      pattern when pattern in @custom_supported_patterns -> true
      nil -> false
      _pattern -> true
    end
  end

  defp signing_pattern(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__signing__, 0) do
      Map.get(module.__signing__(), :pattern)
    end
  end

  defp included?(include, tag) do
    Enum.any?(include, fn
      {^tag, value} -> value != false
      ^tag -> true
      _ -> false
    end)
  end

  defp available_private?(module, method) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__unified_endpoint__, 1),
         [_ | _] = configs <- module.__unified_endpoint__(method) do
      Enum.all?(configs, &(Map.get(&1, :authenticated, false) == true))
    else
      _ -> false
    end
  end

  defp build_setup_gate(exchange_id, exchange_atom) do
    quote do
      setup_all do
        unquote(__MODULE__).__require_explicit_includes!()

        exchange_atom = unquote(exchange_atom)
        exchange_id = unquote(exchange_id)

        passphrase? =
          case Bourse.Exchange.new(exchange_atom) do
            {:ok, ex} -> ex.required_credentials["password"] == true
            _ -> false
          end

        if !Bourse.Testnet.registered?(exchange_atom, :default) do
          raise Bourse.IntegrationHelper.missing_credentials_message(exchange_atom, :default, passphrase: passphrase?)
        end

        try do
          _ = Bourse.Exchange.new!(exchange_atom, sandbox: true)
        rescue
          err in ArgumentError ->
            msg = Exception.message(err)

            if msg =~ "no testnet data" do
              reraise """
                      #{exchange_id}: no testnet data per spec — skipping private dangerous probes.
                        #{msg}
                      """,
                      __STACKTRACE__
            else
              reraise err, __STACKTRACE__
            end
        end

        :ok
      end
    end
  end

  defp build_test(:private_dangerous, exchange_id, exchange_atom, method) do
    quote do
      @tag :private
      @tag :dangerous
      test "#{unquote(exchange_id)} dangerous unified #{unquote(method)} with real creds" do
        config = unquote(__MODULE__).__fetch_config!(unquote(exchange_atom), unquote(method))
        creds = Bourse.IntegrationHelper.require_credentials!(unquote(exchange_atom), sandbox_key: config.sandbox_key)

        exchange =
          Bourse.IntegrationHelper.build_exchange(unquote(exchange_atom),
            credentials: creds,
            sandbox: true
          )

        unquote(__MODULE__).__run_write_case__(unquote(method), exchange, config)
      end
    end
  end

  defp run_write_case(:create_order, exchange, config, api_module) do
    case create_order(api_module, exchange, config) do
      {:ok, body} ->
        id = extract_order_id!(body, :create_order)

        try do
          Bourse.IntegrationHelper.assert_private_response(:create_order, {:ok, body})
        after
          cancel_created_order!(api_module, exchange, config, id)
        end

      result ->
        Bourse.IntegrationHelper.assert_private_response(:create_order, result)
    end
  end

  defp run_write_case(:edit_order, exchange, config, api_module) do
    with_created_order(api_module, exchange, config, fn id ->
      result =
        api_module.edit_order(
          exchange,
          id,
          config.symbol,
          config.order_type,
          config.side,
          edit_order_opts(config)
        )

      Bourse.IntegrationHelper.assert_private_response(:edit_order, result)
    end)
  end

  defp run_write_case(:cancel_order, exchange, config, api_module) do
    with_created_order(api_module, exchange, config, fn id ->
      result = api_module.cancel_order(exchange, id, cancel_order_opts(config))
      Bourse.IntegrationHelper.assert_private_response(:cancel_order, result)
    end)
  end

  defp run_write_case(:cancel_all_orders, exchange, config, api_module) do
    with_created_order(api_module, exchange, config, fn _id ->
      result = api_module.cancel_all_orders(exchange, cancel_all_order_opts(config))
      Bourse.IntegrationHelper.assert_private_response(:cancel_all_orders, result)
    end)
  end

  defp run_write_case(:withdraw, exchange, config, api_module) do
    result = api_module.withdraw(exchange, config.code, config.size, config.address, config.params)
    Bourse.IntegrationHelper.assert_private_response(:withdraw, result)
  end

  defp run_write_case(:transfer, exchange, config, api_module) do
    result =
      api_module.transfer(
        exchange,
        config.code,
        config.size,
        config.from_account,
        config.to_account,
        config.params
      )

    Bourse.IntegrationHelper.assert_private_response(:transfer, result)
  end

  defp with_created_order(api_module, exchange, config, fun) do
    case create_order(api_module, exchange, config) do
      {:ok, body} ->
        id = extract_order_id!(body, :create_order)

        try do
          fun.(id)
        after
          cancel_created_order!(api_module, exchange, config, id)
        end

      result ->
        Bourse.IntegrationHelper.assert_private_response(:create_order, result)
    end
  end

  defp create_order(api_module, exchange, config) do
    api_module.create_order(
      exchange,
      config.symbol,
      config.order_type,
      config.side,
      config.size,
      create_order_opts(config)
    )
  end

  defp cancel_created_order!(api_module, exchange, config, id) do
    case api_module.cancel_order(exchange, id, cancel_order_opts(config)) do
      {:ok, _body} ->
        :ok

      {:error, %CError{type: :order_not_found}} ->
        :ok

      other ->
        flunk("""
        #{exchange.id} cleanup cancel_order failed for #{inspect(id)}:
          #{inspect(other)}
        """)
    end
  end

  defp create_order_opts(config) do
    config.params
    |> Keyword.put(:price, config.price)
    |> put_flag(:postOnly, Map.get(config.safety_flags, :post_only))
    |> put_flag(:reduceOnly, Map.get(config.safety_flags, :reduce_only))
  end

  defp edit_order_opts(config) do
    config
    |> create_order_opts()
    |> Keyword.merge(config.edit_params)
  end

  defp cancel_order_opts(config), do: Keyword.merge([symbol: config.symbol], config.cancel_params)
  defp cancel_all_order_opts(config), do: Keyword.merge([symbol: config.symbol], config.cancel_params)

  defp put_flag(opts, _key, nil), do: opts
  defp put_flag(opts, _key, false), do: opts
  defp put_flag(opts, key, true), do: Keyword.put(opts, key, true)

  defp extract_order_id!(body, method) do
    case extract_order_id(body) do
      nil -> flunk("#{method} response did not include an order id: #{inspect(body)}")
      id -> id
    end
  end

  defp extract_order_id(%{id: id}) when not is_nil(id), do: id
  defp extract_order_id(%{"id" => id}) when not is_nil(id), do: id
  defp extract_order_id(%{"result" => result}), do: extract_order_id(result)
  defp extract_order_id(%{"data" => result}), do: extract_order_id(result)
  defp extract_order_id(_body), do: nil
end
