defmodule Bourse.Test.Generator.TagAtoms do
  @moduledoc """
  Closed-corpus whitelist of ExUnit tag atoms for exchanges and REST-read
  contract methods.

  `Bourse.Spec.exchanges/0` (the venue manifest this client implements) and
  `Bourse.Test.RestReadContracts.cases/0` (the authored REST-read contract
  corpus) are both fixed at compile time — never request/runtime input. The
  atoms below are created exactly once per corpus entry, at compile time,
  from that closed set; every test-generator module looks them up via
  `exchange_tag!/1` / `method_tag!/1` instead of calling `String.to_atom/1`
  itself on a venue- or method-derived string.
  """

  alias Bourse.Test.RestReadContracts

  # Whitelist construction: iterates the closed, compile-time-fixed venue
  # manifest exactly once — never runtime input.
  # reach:disable-next-line unsafe_atom_creation
  @exchange_tags Map.new(Bourse.Spec.exchanges(), &{&1, String.to_atom("exchange_#{&1}")})

  @method_tags Map.new(RestReadContracts.cases(), fn contract_case ->
                 method = contract_case["method"]

                 # Whitelist construction: iterates the closed, compile-time-fixed
                 # REST-read contract corpus exactly once — never runtime input.
                 # reach:disable-next-line unsafe_atom_creation
                 {method, String.to_atom("method_#{Macro.underscore(method)}")}
               end)

  @doc """
  The `:exchange_<id>` ExUnit tag atom for a venue id.

  Raises for a venue outside the manifest: a generator instantiated for a
  venue this client does not implement would emit tests nothing can run, and
  a silently-minted tag atom is how that goes unnoticed.
  """
  @spec exchange_tag!(String.t() | atom()) :: atom()
  def exchange_tag!(exchange_id) when is_atom(exchange_id), do: exchange_tag!(Atom.to_string(exchange_id))

  def exchange_tag!(exchange_id), do: Map.fetch!(@exchange_tags, exchange_id)

  @doc "The `:method_<name>` ExUnit tag atom for a known REST-read-contract method."
  @spec method_tag!(String.t()) :: atom()
  def method_tag!(method), do: Map.fetch!(@method_tags, method)
end
