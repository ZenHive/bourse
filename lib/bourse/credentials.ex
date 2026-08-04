defmodule Bourse.Credentials do
  @moduledoc """
  API credentials for exchange authentication.

  Requires `api_key` and `secret` at minimum. Some exchanges also need
  `password` (OKX, KuCoin) or `uid`.

  Credentials are always passed explicitly — this module never reads
  from environment variables or application config.

  ## Examples

      {:ok, creds} = Bourse.Credentials.new(api_key: "abc", secret: "xyz")

      creds = Bourse.Credentials.new!(api_key: "abc", secret: "xyz", sandbox: true)

  """

  @type t :: %__MODULE__{
          api_key: String.t(),
          secret: String.t(),
          password: String.t() | nil,
          uid: String.t() | nil,
          sandbox: boolean()
        }

  @enforce_keys [:api_key, :secret]
  defstruct [:api_key, :secret, :password, :uid, sandbox: false]

  @doc """
  Creates credentials from a keyword list.

  Returns `{:ok, credentials}` or `{:error, reason}`.

  ## Examples

      {:ok, creds} = Bourse.Credentials.new(api_key: "abc", secret: "xyz")
      {:error, :missing_api_key} = Bourse.Credentials.new(secret: "xyz")

  """
  @allowed_keys [:api_key, :secret, :password, :uid, :sandbox]

  @spec new(keyword()) ::
          {:ok, t()}
          | {:error,
             :missing_api_key
             | :missing_secret
             | {:invalid_type, atom()}
             | {:unknown_key, atom()}}
  def new(opts) when is_list(opts) do
    with :ok <- validate_keys(opts),
         :ok <- validate_required(opts),
         :ok <- validate_types(opts) do
      {:ok, struct!(__MODULE__, opts)}
    end
  end

  @string_fields [:api_key, :secret, :password, :uid]

  # Validates no unknown keys are present
  defp validate_keys(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in @allowed_keys)) do
      nil -> :ok
      key -> {:error, {:unknown_key, key}}
    end
  end

  # Validates required fields are present
  defp validate_required(opts) do
    cond do
      is_nil(Keyword.get(opts, :api_key)) -> {:error, :missing_api_key}
      is_nil(Keyword.get(opts, :secret)) -> {:error, :missing_secret}
      true -> :ok
    end
  end

  # Validates string fields are strings when present
  defp validate_types(opts) do
    case Enum.find(@string_fields, fn key ->
           value = Keyword.get(opts, key)
           not is_nil(value) and not is_binary(value)
         end) do
      nil -> :ok
      key -> {:error, {:invalid_type, key}}
    end
  end

  @doc """
  Creates credentials from a keyword list, raising on invalid input.

  ## Examples

      creds = Bourse.Credentials.new!(api_key: "abc", secret: "xyz")

  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, credentials} ->
        credentials

      {:error, :missing_api_key} ->
        raise ArgumentError, "api_key is required"

      {:error, :missing_secret} ->
        raise ArgumentError, "secret is required"

      {:error, {:unknown_key, key}} ->
        raise ArgumentError, "unknown key: #{inspect(key)}"

      {:error, {:invalid_type, key}} ->
        raise ArgumentError, "#{key} must be a string, got: #{inspect(Keyword.get(opts, key))}"
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    # Secrets must never reach logs, crash reports, or IEx output through
    # default struct printing. The `#Bourse.Credentials<...>` form (vs `%{...}`)
    # signals the output is not a reconstructible literal.
    def inspect(credentials, opts) do
      fields = [
        api_key: redact(credentials.api_key),
        secret: redact(credentials.secret),
        password: redact(credentials.password),
        uid: redact(credentials.uid),
        sandbox: credentials.sandbox
      ]

      container_doc("#Bourse.Credentials<", fields, ">", opts, fn {key, value}, opts ->
        concat("#{key}: ", to_doc(value, opts))
      end)
    end

    defp redact(nil), do: nil
    defp redact(value) when is_binary(value), do: "***"
  end
end
