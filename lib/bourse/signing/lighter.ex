defmodule Bourse.Signing.Lighter do
  @moduledoc """
  Lighter zk-Schnorr signing through an isolated official Go helper.

  The API signing key crosses stdin exactly once into a per-key external OS
  process. The helper is temporary and terminating it removes that key from the
  signing subsystem. Network transport remains in `Bourse.HTTP`.
  """

  @behaviour Bourse.Signing.Behaviour

  alias Bourse.Credentials
  alias Bourse.Signing.Lighter.Worker
  alias Bourse.Signing.Request
  alias Bourse.Signing.SignedRequest

  @mainnet_chain_id 304
  @testnet_chain_id 300
  @private_key_bytes 40
  @authorization_header "Authorization"
  @content_type_header {"Content-Type", "application/x-www-form-urlencoded"}
  @transaction_operation_key "__bourse_lighter_transaction_operation"
  @transaction_params_key "__bourse_lighter_transaction_params"
  @transaction_operations %{
    "cancel_order" => :cancel_order,
    "create_order" => :create_order
  }
  @internal_param_keys [
    :api_key_index,
    "api_key_index",
    "apiKeyIndex",
    :auth_deadline,
    "auth_deadline",
    "authDeadline",
    :chain_id,
    "chain_id",
    "chainId"
  ]

  @type signing_error ::
          {:lighter_signing,
           :invalid_credentials
           | :invalid_configuration
           | :helper_unavailable
           | :helper_terminated
           | Bourse.Signing.Lighter.Protocol.protocol_error()}

  @impl true
  @spec sign(Request.t(), Credentials.t(), map()) :: SignedRequest.t() | {:error, signing_error()}
  def sign(
        %Request{method: :post, params: %{@transaction_operation_key => operation} = request_params} = request,
        %Credentials{} = credentials,
        config
      ) do
    with {:ok, operation} <- transaction_operation(operation),
         {:ok, transaction_params} <- transaction_params(request_params),
         {:ok, transaction} <- sign_transaction(operation, transaction_params, credentials, config) do
      %SignedRequest{
        url: request.path,
        method: request.method,
        headers: [@content_type_header],
        body: transaction_body(transaction)
      }
    end
  end

  def sign(%Request{} = request, %Credentials{} = credentials, config) do
    with {:ok, context} <- context(credentials, request.params, config),
         {:ok, token} <- request_helper(context, :auth_token, %{deadline: auth_deadline(request.params, config)}) do
      params = Map.drop(request.params, @internal_param_keys)

      %SignedRequest{
        url: signed_url(request.path, request.body, params),
        method: request.method,
        headers: [{@authorization_header, token}],
        body: request.body
      }
    end
  end

  @doc "Signs a supported Lighter transaction using the same per-key helper."
  @spec sign_transaction(Bourse.Signing.Lighter.Protocol.operation(), map(), Credentials.t(), map()) ::
          {:ok, Bourse.Signing.Lighter.Protocol.signed_transaction()} | {:error, signing_error()}
  def sign_transaction(operation, params, %Credentials{} = credentials, config) when is_map(params) and is_map(config) do
    with {:ok, context} <- context(credentials, params, config) do
      request_helper(context, operation, params)
    end
  end

  @doc "Terminates the helper that owns these credentials."
  @spec terminate_helper(Credentials.t(), map()) :: :ok | {:error, signing_error()}
  def terminate_helper(%Credentials{} = credentials, config) do
    with {:ok, context} <- context(credentials, %{}, config) do
      Worker.terminate(context.identity)
    end
  end

  @doc false
  @spec helper_info(Credentials.t(), map()) ::
          {:ok, %{pid: pid(), os_pid: non_neg_integer() | nil}}
          | {:error, :not_running | signing_error()}
  def helper_info(%Credentials{} = credentials, config) do
    with {:ok, context} <- context(credentials, %{}, config) do
      Worker.helper_info(context.identity)
    end
  end

  defp request_helper(context, operation, params) do
    init_options = %{
      url: context.url,
      private_key: context.private_key,
      chain_id: context.chain_id,
      api_key_index: context.api_key_index,
      account_index: context.account_index,
      helper_path: context.helper_path,
      helper_args: context.helper_args
    }

    case Worker.request(context.identity, init_options, operation, params) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:lighter_signing, reason}}
    end
  end

  defp transaction_operation(operation) do
    case Map.fetch(@transaction_operations, operation) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, {:lighter_signing, :invalid_configuration}}
    end
  end

  defp transaction_params(%{@transaction_params_key => params}) when is_map(params), do: {:ok, params}
  defp transaction_params(_params), do: {:error, {:lighter_signing, :invalid_configuration}}

  defp transaction_body(%{tx_type: tx_type, tx_info: tx_info}) do
    URI.encode_query(%{"tx_info" => tx_info, "tx_type" => tx_type})
  end

  defp context(credentials, params, config) do
    options = Map.get(config, :exchange_options, %{})

    with {:ok, private_key} <- private_key(credentials.secret),
         {:ok, api_key_index} <- integer_option(params, options, config, :api_key_index, credentials.api_key),
         {:ok, account_index} <- integer_option(params, options, config, :account_index, credentials.uid),
         {:ok, chain_id} <- integer_option(params, options, config, :chain_id, default_chain_id(config)),
         {:ok, url} <- binary_option(config, :base_url),
         {:ok, helper_path} <- helper_path(config),
         :ok <- valid_context(api_key_index, account_index, chain_id) do
      identity =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({url, private_key, chain_id, api_key_index, account_index})
        )

      {:ok,
       %{
         identity: identity,
         url: url,
         private_key: private_key,
         api_key_index: api_key_index,
         account_index: account_index,
         chain_id: chain_id,
         helper_path: helper_path,
         helper_args: Map.get(config, :helper_args, [])
       }}
    else
      {:error, :invalid_credentials} -> {:error, {:lighter_signing, :invalid_credentials}}
      _error -> {:error, {:lighter_signing, :invalid_configuration}}
    end
  end

  defp private_key(secret) when is_binary(secret) do
    normalized = if String.starts_with?(secret, "0x"), do: binary_part(secret, 2, byte_size(secret) - 2), else: secret

    case Base.decode16(normalized, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == @private_key_bytes -> {:ok, normalized}
      _ -> {:error, :invalid_credentials}
    end
  end

  defp private_key(_secret), do: {:error, :invalid_credentials}

  defp integer_option(params, options, config, name, default) do
    value = first_option(params, options, config, option_names(name), default)

    case value do
      integer when is_integer(integer) ->
        {:ok, integer}

      string when is_binary(string) ->
        case Integer.parse(string) do
          {integer, ""} -> {:ok, integer}
          _ -> {:error, :invalid_configuration}
        end

      _ ->
        {:error, :invalid_configuration}
    end
  end

  defp binary_option(config, name) do
    case Map.get(config, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_configuration}
    end
  end

  defp helper_path(config) do
    case Map.get(config, :helper_path, default_helper_path()) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :invalid_configuration}
    end
  end

  defp first_option(params, options, config, names, default) do
    [params, options, config]
    |> Enum.find_value(default, &fetch_first(&1, names))
    |> case do
      {:found, value} -> value
      value -> value
    end
  end

  defp fetch_first(source, names) do
    Enum.find_value(names, fn name ->
      case Map.fetch(source, name) do
        {:ok, value} -> {:found, value}
        :error -> nil
      end
    end)
  end

  defp option_names(:api_key_index), do: [:api_key_index, "api_key_index", "apiKeyIndex"]
  defp option_names(:account_index), do: [:account_index, "account_index", "accountIndex"]
  defp option_names(:chain_id), do: [:chain_id, "chain_id", "chainId"]

  defp default_chain_id(%{testnet: true}), do: @testnet_chain_id
  defp default_chain_id(_config), do: @mainnet_chain_id

  defp valid_context(api_key_index, account_index, chain_id)
       when api_key_index in 0..255 and account_index > 0 and chain_id in 1..0x7FFFFFFF, do: :ok

  defp valid_context(_api_key_index, _account_index, _chain_id), do: {:error, :invalid_configuration}

  defp auth_deadline(params, config) do
    value = first_option(params, %{}, config, [:auth_deadline, "auth_deadline", "authDeadline"], 0)
    if is_integer(value) and value >= 0, do: value, else: 0
  end

  defp signed_url(path, nil, params) when map_size(params) > 0, do: path <> "?" <> Bourse.Signing.urlencode(params)

  defp signed_url(path, _body, _params), do: path

  defp default_helper_path do
    Application.app_dir(:bourse, ["priv", "native", "lighter_signer", platform_target(), executable_name()])
  end

  defp platform_target do
    os = if match?({:win32, _}, :os.type()), do: "windows", else: unix_os()

    architecture =
      :system_architecture
      |> :erlang.system_info()
      |> List.to_string()
      |> then(fn system_architecture ->
        if String.contains?(system_architecture, ["aarch64", "arm64"]), do: "arm64", else: "amd64"
      end)

    "#{os}-#{architecture}"
  end

  defp unix_os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, _name} -> "linux"
    end
  end

  defp executable_name do
    if match?({:win32, _}, :os.type()), do: "bourse_lighter_signer.exe", else: "bourse_lighter_signer"
  end
end
