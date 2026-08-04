if Bourse.Test.Generator.OptIn.requested?([:network, :public_probe]) do
  defmodule Bourse.PublicEndpointProbeTest do
    @moduledoc """
    Task 40 — Public-Endpoint Pipeline Probe.

    Opt-in suite: file-level `@moduletag :network` keeps the default
    `mix test` run offline. To execute:

        mix test.json --quiet --only network test/bourse/public_endpoint_probe_test.exs

    Expect a mix of passes, `⚠️  INCONCLUSIVE` Logger warnings for rate-limit /
    geo-block cases, and flunks that pinpoint exchanges whose public pipeline
    (URL resolution → transport → response parsing) is broken. Zero flunks on
    an otherwise-healthy network means the raw public surface is sound across
    the fleet.
    """

    use ExUnit.Case, async: false
    use Bourse.Test.Generator.PublicEndpointProbe

    # @moduletag :network and :public_probe are emitted from inside the
    # generator's __using__/1 quote — if declared here they would not attach to
    # the already-registered tests. See the generator for the ordering rationale.
  end
end
