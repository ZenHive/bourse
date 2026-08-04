defmodule Bourse.Test.AssetConfig do
  @moduledoc """
  Explicit test-asset configuration for dangerous unified write probes.

  Each entry is keyed by `{exchange_id, method}`. There are intentionally no
  fallback defaults: a write-path integration test must name the sandbox asset,
  order size, safety flags, and cleanup behavior before it can touch an exchange.
  """

  @enforce_keys [:exchange_id, :method, :safety_flags, :cleanup]
  defstruct [
    :exchange_id,
    :method,
    :symbol,
    :size,
    :price,
    :order_type,
    :side,
    :code,
    :address,
    :from_account,
    :to_account,
    sandbox_key: :default,
    params: [],
    edit_params: [],
    cancel_params: [],
    safety_flags: %{},
    cleanup: %{}
  ]

  @type write_method ::
          :create_order
          | :edit_order
          | :cancel_order
          | :cancel_all_orders
          | :withdraw
          | :transfer

  @type t :: %__MODULE__{
          exchange_id: atom(),
          method: write_method(),
          symbol: String.t() | nil,
          size: term(),
          price: term(),
          order_type: String.t() | nil,
          side: String.t() | nil,
          code: String.t() | nil,
          address: String.t() | nil,
          from_account: String.t() | nil,
          to_account: String.t() | nil,
          sandbox_key: atom(),
          params: keyword(),
          edit_params: keyword(),
          cancel_params: keyword(),
          safety_flags: map(),
          cleanup: map()
        }

  @write_methods [:create_order, :edit_order, :cancel_order, :cancel_all_orders, :withdraw, :transfer]
  @order_methods [:create_order, :edit_order, :cancel_order, :cancel_all_orders]
  @configs []

  @doc "Returns the dangerous unified write methods covered by the probe."
  @spec methods() :: [write_method()]
  def methods, do: @write_methods

  @doc "Returns the configured test assets keyed by `{exchange_id, method}`."
  @spec all() :: %{{atom(), write_method()} => t()}
  def all, do: Map.new(@configs)

  @doc "Fetches a configured dangerous test asset."
  @spec fetch(atom() | String.t(), write_method()) ::
          {:ok, t()} | {:error, {:missing_asset_config, atom(), write_method()}}
  def fetch(exchange_id, method) when method in @write_methods do
    exchange = normalize_exchange!(exchange_id)

    case Map.fetch(all(), {exchange, method}) do
      {:ok, %__MODULE__{} = config} -> {:ok, config}
      :error -> {:error, {:missing_asset_config, exchange, method}}
    end
  end

  @doc "Builds and validates a dangerous test-asset config."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    attrs
    |> new()
    |> case do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc "Builds and validates a dangerous test-asset config."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    config = struct(__MODULE__, normalize_attrs(attrs))

    with :ok <- validate_method(config),
         :ok <- validate_common(config),
         :ok <- validate_method_fields(config),
         :ok <- validate_safety(config),
         :ok <- validate_cleanup(config) do
      {:ok, config}
    end
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Map.update(:exchange_id, nil, &normalize_exchange!/1)
    |> Map.update(:sandbox_key, :default, &normalize_atom!/1)
    |> Map.update(:safety_flags, %{}, &normalize_map!/1)
    |> Map.update(:cleanup, %{}, &normalize_map!/1)
    |> Map.update(:params, [], &normalize_keyword!/1)
    |> Map.update(:edit_params, [], &normalize_keyword!/1)
    |> Map.update(:cancel_params, [], &normalize_keyword!/1)
  end

  defp validate_method(%__MODULE__{method: method}) when method in @write_methods, do: :ok
  defp validate_method(%__MODULE__{method: method}), do: {:error, "unsupported dangerous method: #{inspect(method)}"}

  defp validate_common(%__MODULE__{exchange_id: nil}), do: {:error, "exchange_id is required"}
  defp validate_common(%__MODULE__{safety_flags: flags}) when flags == %{}, do: {:error, "safety_flags is required"}
  defp validate_common(%__MODULE__{cleanup: cleanup}) when cleanup == %{}, do: {:error, "cleanup is required"}
  defp validate_common(%__MODULE__{}), do: :ok

  defp validate_method_fields(%__MODULE__{method: method} = config) when method in @order_methods do
    require_fields(config, [:symbol, :size, :price, :order_type, :side])
  end

  defp validate_method_fields(%__MODULE__{method: :withdraw} = config) do
    require_fields(config, [:code, :size, :address])
  end

  defp validate_method_fields(%__MODULE__{method: :transfer} = config) do
    require_fields(config, [:code, :size, :from_account, :to_account])
  end

  defp validate_safety(%__MODULE__{safety_flags: flags, method: method}) when method in @order_methods do
    if Map.get(flags, :sandbox_only) == true do
      validate_order_safety(flags)
    else
      {:error, "safety_flags.sandbox_only must be true"}
    end
  end

  defp validate_safety(%__MODULE__{safety_flags: %{sandbox_only: true}}), do: :ok
  defp validate_safety(%__MODULE__{}), do: {:error, "safety_flags.sandbox_only must be true"}

  defp validate_order_safety(flags) do
    if Map.get(flags, :post_only) == true do
      :ok
    else
      {:error, "safety_flags.post_only must be true for order-write probes"}
    end
  end

  defp validate_cleanup(%__MODULE__{method: method, cleanup: %{cancel_after_create: true}}) when method in @order_methods,
    do: :ok

  defp validate_cleanup(%__MODULE__{method: method}) when method in @order_methods do
    {:error, "cleanup.cancel_after_create must be true for order-write probes"}
  end

  defp validate_cleanup(%__MODULE__{}), do: :ok

  defp require_fields(config, fields) do
    missing =
      Enum.filter(fields, fn field ->
        value = Map.fetch!(config, field)
        is_nil(value) or value == ""
      end)

    case missing do
      [] -> :ok
      fields -> {:error, "missing required fields: #{inspect(fields)}"}
    end
  end

  defp normalize_exchange!(exchange) when is_atom(exchange), do: exchange
  defp normalize_exchange!(exchange) when is_binary(exchange), do: String.to_atom(exchange)
  defp normalize_exchange!(exchange), do: raise(ArgumentError, "invalid exchange_id: #{inspect(exchange)}")

  defp normalize_atom!(value) when is_atom(value), do: value
  defp normalize_atom!(value) when is_binary(value), do: String.to_atom(value)
  defp normalize_atom!(value), do: raise(ArgumentError, "invalid atom value: #{inspect(value)}")

  defp normalize_map!(value) when is_map(value), do: value
  defp normalize_map!(value) when is_list(value), do: Map.new(value)
  defp normalize_map!(value), do: raise(ArgumentError, "invalid map value: #{inspect(value)}")

  defp normalize_keyword!(value) when is_list(value), do: value
  defp normalize_keyword!(value) when is_map(value), do: Map.to_list(value)
  defp normalize_keyword!(value), do: raise(ArgumentError, "invalid keyword value: #{inspect(value)}")
end
