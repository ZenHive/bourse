defmodule Bourse.Test.LiveLane do
  @moduledoc """
  Asks `Bourse.LiveLane.Ledger` whether a live outcome is a classified red.

  Live integration tests use this instead of a hand-maintained skip list.
  """

  import ExUnit.Assertions

  alias Bourse.LiveLane.Ledger
  alias Bourse.Unified

  @doc "Records a ledgered empty or sparse outcome, or flunks a genuine one."
  @spec accept_or_flunk!(String.t() | atom(), String.t() | atom(), term(), String.t(), String.t()) :: :ok
  def accept_or_flunk!(venue, method, observed, genuine_message, suffix \\ "live") do
    case Ledger.accept(contract_case(venue, method, suffix), observed) do
      {:ledgered, _entry} -> :ok
      :genuine -> flunk(genuine_message)
    end
  end

  @doc "Builds the contract-case map the ledger classifier consumes."
  @spec contract_case(String.t() | atom(), String.t() | atom(), String.t()) :: map()
  def contract_case(venue, method, suffix \\ "live") do
    venue = to_string(venue)
    js_name = js_name(method)
    %{"venue" => venue, "method" => js_name, "id" => "#{venue}:#{js_name}:#{suffix}"}
  end

  defp js_name(method) when is_atom(method), do: Unified.js_name_for!(method)
  defp js_name(method) when is_binary(method), do: method
end
