defmodule Bourse.Registry do
  @moduledoc """
  Compile-time exchange lookup registry.

  Maps exchange ID atoms and strings to their generated module names.
  Built from the spec manifest at compile time — recompiles automatically
  when the manifest changes.

  ## Usage

      Bourse.Registry.lookup(:bybit)
      #=> {:ok, Bourse.Bybit}

      Bourse.Registry.lookup!("binance")
      #=> Bourse.Binance

      Bourse.Registry.exchanges()
      #=> ["alpaca", "binance", ..., "okx"]

      Bourse.Registry.loaded?(:bybit)
      #=> true  # if Bourse.Bybit module is compiled

  """

  @manifest_path Bourse.Spec.manifest_path()
  @external_resource @manifest_path

  @exchange_ids Bourse.Spec.exchanges()

  # Pre-compute the ID-to-module mapping at compile time
  @exchange_modules (for id <- @exchange_ids, into: %{} do
                       {id, Module.concat(Bourse, Macro.camelize(id))}
                     end)

  @doc """
  Looks up the module for an exchange ID.

  Accepts both string and atom IDs.

  ## Examples

      Bourse.Registry.lookup("bybit")
      #=> {:ok, Bourse.Bybit}

      Bourse.Registry.lookup(:kraken)
      #=> {:error, {:unsupported_exchange, "kraken"}}

  """
  @spec lookup(String.t() | atom()) :: {:ok, module()} | {:error, {:unsupported_exchange, String.t()}}
  def lookup(id) when is_atom(id), do: lookup(Atom.to_string(id))

  for {id, module} <- @exchange_modules do
    def lookup(unquote(id)), do: {:ok, unquote(module)}
  end

  def lookup(id) when is_binary(id), do: {:error, {:unsupported_exchange, id}}

  @doc """
  Looks up the module for an exchange ID, raising on unknown.

  ## Examples

      Bourse.Registry.lookup!(:bybit)
      #=> Bourse.Bybit

  """
  @spec lookup!(String.t() | atom()) :: module()
  def lookup!(id) do
    case lookup(id) do
      {:ok, module} -> module
      {:error, _} -> raise ArgumentError, "unsupported exchange: #{inspect(id)}"
    end
  end

  @doc """
  Returns the module for an exchange ID, or nil if unsupported.

  ## Examples

      Bourse.Registry.module_for("bybit")
      #=> Bourse.Bybit

      Bourse.Registry.module_for("nope")
      #=> nil

  """
  @spec module_for(String.t() | atom()) :: module() | nil
  def module_for(id) do
    case lookup(id) do
      {:ok, module} -> module
      {:error, _} -> nil
    end
  end

  @doc """
  Returns the closed runtime-support inventory as strings.

  ## Examples

      Bourse.Registry.exchanges()
      #=> ["alpaca", "binance", ..., "okx"]

  """
  @spec exchanges() :: [String.t()]
  def exchanges, do: Enum.sort(@exchange_ids)

  @doc """
  Checks if an exchange ID is registered.

  ## Examples

      Bourse.Registry.registered?(:bybit)
      #=> true

  """
  @spec registered?(String.t() | atom()) :: boolean()
  def registered?(id) when is_atom(id), do: registered?(Atom.to_string(id))
  def registered?(id) when is_binary(id), do: Map.has_key?(@exchange_modules, id)

  @doc """
  Checks if the exchange module is compiled and loaded.

  Returns true only if the exchange is registered AND its module is
  available in the BEAM. Useful for distinguishing "known exchange"
  from "exchange module exists."

  ## Examples

      Bourse.Registry.loaded?(:bybit)
      #=> true  # if Bourse.Bybit is compiled

  """
  @spec loaded?(String.t() | atom()) :: boolean()
  def loaded?(id) do
    case lookup(id) do
      {:ok, module} -> Code.ensure_loaded?(module)
      {:error, _} -> false
    end
  end
end
