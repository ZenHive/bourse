defmodule Bourse.Signing.Behaviour do
  @moduledoc """
  Behaviour for signing pattern implementations.

  First-party signing executors implement `sign/3` and are dispatched through
  `Bourse.Signing.sign/4`. Runtime specs select only the closed built-in set.

  ## Available Helpers

  `Bourse.Signing` provides crypto and encoding helpers:
  `timestamp_ms/0`, `hmac_sha256/2`, `hmac_sha384/2`, `hmac_sha512/2`,
  `sha256/1`, `sha512/1`, `encode_hex/1`, `encode_base64/1`,
  `decode_base64/1`, `urlencode/1`, `urlencode_raw/1`.
  """

  alias Bourse.Credentials
  alias Bourse.Signing

  @doc """
  Signs a request using the pattern's authentication method.

  ## Parameters

  - `request` - `Bourse.Signing.Request` with `:method`, `:path`, `:body`, and `:params`
  - `credentials` - `Bourse.Credentials` struct with API key and secret
  - `config` - Pattern-specific configuration from the exchange spec

  ## Returns

  A `Bourse.Signing.SignedRequest` with `:url`, `:method`, `:headers`, and `:body`.
  """
  @callback sign(
              request :: Signing.request(),
              credentials :: Credentials.t(),
              config :: Signing.config()
            ) :: Signing.signed_request()
end
