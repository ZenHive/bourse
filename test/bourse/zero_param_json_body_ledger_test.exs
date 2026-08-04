defmodule Bourse.ZeroParamJsonBodyLedgerTest do
  @moduledoc false
  # We always send and sign `{}` on a JSON-body POST/PUT/PATCH (task 369), while
  # the CCXT compatibility reference omits the body for a set of venues. That
  # divergence stays open until live provider evidence settles it.
  #
  # Which venues are gated is a corpus-wide question and is asserted in the
  # workbench, against every venue CCXT describes. This asserts the half that
  # only the client can answer: every gated venue we actually *support* is a
  # venue we can reach, so it must carry an entry in the prod-verification
  # ledger rather than sitting as an unrecorded divergence.
  use ExUnit.Case, async: true

  @ledger_path Path.expand("../../docs/prod-verification-ledger.md", __DIR__)
  @external_resource @ledger_path

  # The supported intersection of the workbench's audited gate set.
  @gated_supported ~w(alpaca okx)

  test "every supported gated venue is named in the prod-verification ledger" do
    ledger = File.read!(@ledger_path)

    assert [] == Enum.reject(@gated_supported, &String.contains?(ledger, &1)),
           """
           A supported venue gates its JSON body in the CCXT reference but has no
           entry in docs/prod-verification-ledger.md.

           Reachable venues do not get to stay unrecorded divergences: probe the
           venue live and record the outcome, or close the divergence.
           """
  end

  test "the supported gate set stays inside the runtime support manifest" do
    supported = MapSet.new(Bourse.Registry.exchanges())

    for venue <- @gated_supported do
      assert MapSet.member?(supported, venue),
             "#{venue} is listed as a supported gated venue but is not a runtime venue"
    end
  end
end
