defmodule Bourse.NoFakedProviderOracleTest do
  @moduledoc """
  Repo-wide guard: no test may grade this client against a faked provider.

  `critical-rules.md` § LIVE E2E FIRST — the live call is the oracle. A stub, a
  recording or a hardcoded response body is a claim about a venue with no
  authority behind it, and it stays green forever after the venue changes. The
  whole fixture and `Req.Test` architecture was deleted for that reason; this
  test is what stops it growing back one convenient helper at a time.
  """
  use ExUnit.Case, async: true

  # Substrings, not regexes: each names a mechanism for answering an HTTP call
  # without reaching the provider, or a committed capture standing in for one.
  @forbidden [
    {"Req.Test", "stubs the transport — the venue never answers"},
    {"Bypass", "runs a fake HTTP server in place of the venue"},
    {"Mox", "mocks the client boundary the live call would cross"},
    {"plug: {", "injects a plug in place of the provider's host"},
    {"test/fixtures", "reads a committed capture as if it were the provider"},
    {"fixtures/responses", "reads a committed provider body"},
    {"fixtures/recorded_errors", "reads a committed provider error"},
    {"fixtures/exchange_accepted_requests", "reads a committed signed request"},
    {"fixtures/public_accepted_requests", "reads a committed signed request"},
    {"fixtures/provider_operations", "reads a committed provider capture"},
    {"RecordedResponseFixtures", "replays a recorded provider body"},
    {"ExchangeAcceptanceFixtures", "replays a recorded signed request"},
    {"PublicAcceptedRequests", "replays a recorded signed request"},
    {"OracleProvenance", "grades against the deleted replay corpus"},
    {"ReplayExchange", "builds an exchange from a frozen cache"}
  ]

  # `priv/specs` and `priv/venues` are pinned third-party/provider reference
  # material. Reading them to pick a symbol or to validate a manifest is not a
  # venue claim; only asserting behaviour from a stored response is.
  @self Path.relative_to_cwd(__ENV__.file)

  test "no test file fakes a provider response" do
    offenders =
      "test/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @self))
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        for {needle, why} <- @forbidden, String.contains?(source, needle) do
          "  #{path}: #{needle} — #{why}"
        end
      end)
      |> Enum.sort()

    assert offenders == [],
           """
           These files answer for a provider instead of calling it:

           #{Enum.join(offenders, "\n")}

           A test that needs a venue must reach the venue. If it cannot — no
           sandbox host, no credentials, no reachable endpoint — it fails loudly
           and the branch is recorded in docs/prod-verification-ledger.md as
           unverified. It does not get a stand-in.
           """
  end

  test "no test opts itself out of running" do
    offenders =
      "test/**/*.exs"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @self))
      |> Enum.filter(&(File.read!(&1) =~ ~r/@(module)?tag\s+:skip\b|@(module)?tag\s+skip:/))
      |> Enum.sort()

    assert offenders == [],
           """
           These files carry a skip tag:

           #{Enum.join(offenders, "\n")}

           A skipped test reports neither pass nor fail, which reads as coverage
           in every summary that counts it. Delete it or make it fail.
           """
  end
end
