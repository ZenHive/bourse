defmodule Bourse.JourneyVenueCoverageTest do
  @moduledoc """
  Repo-wide guard: every credentialed runtime venue carries a live journey and
  an error-probe suite.

  The REST-read lane already locks its own mirror — `Bourse.Test.RestReadContracts`
  refuses an inventory that does not cover every runtime venue, so a new read
  branch cannot ship unexercised. The journey lane is the *semantic* half of the
  same contract (`CLAUDE.md` § "Journeys — the semantic lane") and had no such
  lock: the ten suites existed because ten tasks each added one, not because
  anything failed when one was missing. Venue twelve would have shipped with no
  role coverage and nothing would have gone red.

  The credentialed set is computed from authored data, never hand-listed: a
  venue is credentialed when its authored `auth.signing_pattern` is non-null.
  Public-only venues (coinbaseexchange) have no private surface for a role to
  exercise and are excluded by that same fact rather than by a constant.
  """
  use ExUnit.Case, async: true

  alias Bourse.JsonDocument

  @runtime_support "priv/venues/runtime_support.json"
  @external_resource @runtime_support

  defp runtime_venues do
    @runtime_support |> JsonDocument.decode_file!() |> Map.fetch!("venues")
  end

  defp credentialed?(venue) do
    "priv/venues/#{venue}/authored/venue.json"
    |> JsonDocument.decode_file!()
    |> get_in(["auth", "signing_pattern"])
    |> is_binary()
  end

  test "every credentialed runtime venue has a trader journey and an error-probe suite" do
    missing =
      for venue <- runtime_venues(),
          credentialed?(venue),
          {kind, path} <- [
            {"trader journey", "test/live/journeys/trader/#{venue}_test.exs"},
            {"error probes", "test/live/errors/#{venue}_test.exs"}
          ],
          not File.exists?(path) do
        "  #{venue}: missing #{kind} — expected #{path}"
      end

    assert missing == [],
           """
           These credentialed venues have no role coverage:

           #{Enum.join(missing, "\n")}

           A venue is supported when its private surface is proven against its
           own host, not when it merely compiles. The trader journey plays one
           role top to bottom with real sandbox orders and its own cleanup; the
           error-probe suite pins the venue's rejections as first observed live.
           Add both alongside the venue's authored document and its
           rest_read_contract.json entry — see CLAUDE.md § "Journeys — the
           semantic lane".

           If the venue is genuinely public-only, it must author
           `auth.signing_pattern = null`, which excludes it here by construction.
           """
  end

  test "the credentialed set is derived, and coinbaseexchange is the only public-only venue" do
    {public_only, credentialed} = Enum.split_with(runtime_venues(), &(not credentialed?(&1)))

    assert public_only == ["coinbaseexchange"],
           """
           The public-only set changed: #{inspect(public_only)}.

           This test is not a hand-list to update — it pins the one venue whose
           authored `auth.signing_pattern` is null. A venue appearing here has
           either lost its signing pattern (a spec defect) or is a genuinely new
           public-only venue, in which case update this assertion and say why in
           the commit.
           """

    assert length(credentialed) == length(runtime_venues()) - 1
  end
end
