defmodule Mix.Tasks.Bourse.ProvisionLighter do
  @shortdoc "Provisions a Lighter testnet account (faucet + ChangePubKey)"

  @moduledoc """
  Creates a Lighter testnet account for an L1 wallet and registers the
  configured zk API public key.

      mix bourse.provision_lighter \\
        --l1-address 0x… \\
        --l1-private-key 0x…

  Flags win over environment. The L1 pair falls back to
  `LIGHTER_TESTNET_L1_ADDRESS` / `LIGHTER_TESTNET_L1_PRIVATE_KEY` — this task
  is the only place in the repo that reads those. The zk API key falls back to
  `LIGHTER_TESTNET_API_PRIVATE_KEY` / `LIGHTER_TESTNET_API_KEY_INDEX`.

  The L1 private key is signed in Elixir and never sent to the native helper.
  """

  use Mix.Task

  alias Bourse.Credentials
  alias Bourse.LighterProvision
  alias Bourse.Signing.Lighter
  alias Mix.Tasks.Bourse.BuildLighterSigner
  alias Mix.Tasks.Bourse.CheckLighterSigner

  @switches [
    l1_address: :string,
    l1_private_key: :string,
    api_private_key: :string,
    api_key_index: :integer,
    base_url: :string,
    chain_id: :integer
  ]

  @account_poll_attempts 30
  @account_poll_ms 1_000
  @req_receive_timeout_ms 15_000

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)
    ensure_valid_args!(invalid)
    config = settings!(opts)
    ensure_go!()
    ensure_helper!()

    {:ok, _} = Application.ensure_all_started(:bourse)

    faucet!(config)
    account_index = wait_for_account!(config)
    pub_key = derive_pub_key!(config.api_private_key)
    nonce = next_nonce!(config, account_index)
    message = LighterProvision.l1_message(pub_key, nonce, account_index, config.api_key_index)
    signature = LighterProvision.sign_l1_message(message, config.l1_private_key)
    assert_signer!(config.l1_address, message, signature)

    transaction = sign_change_pub_key!(config, account_index, pub_key, signature, nonce)
    send_tx!(config, transaction)
    verify_registration!(config, account_index, pub_key, nonce)

    Mix.shell().info("account_index=#{account_index}")
    Mix.shell().info("api_key_index=#{config.api_key_index}")
    :ok
  end

  defp settings!(opts) do
    l1_address = flag_or_env!(opts, :l1_address, "LIGHTER_TESTNET_L1_ADDRESS", l1_missing_text())
    l1_private_key = flag_or_env!(opts, :l1_private_key, "LIGHTER_TESTNET_L1_PRIVATE_KEY", l1_missing_text())
    api_private_key = flag_or_env!(opts, :api_private_key, "LIGHTER_TESTNET_API_PRIVATE_KEY", api_missing_text())
    api_key_index = integer_flag_or_env!(opts, :api_key_index, "LIGHTER_TESTNET_API_KEY_INDEX", api_missing_text())

    %{
      l1_address: LighterProvision.normalize_address(l1_address),
      l1_private_key: l1_private_key,
      api_private_key: api_private_key,
      api_key_index: api_key_index,
      base_url: Keyword.get(opts, :base_url) || LighterProvision.testnet_url(),
      chain_id: Keyword.get(opts, :chain_id, LighterProvision.testnet_chain_id())
    }
  end

  defp faucet!(config) do
    url = config.base_url <> "/api/v1/faucet?l1_address=" <> URI.encode_www_form(config.l1_address)

    case get_json(url) do
      {:ok, body} -> accept_faucet!(body)
      {:error, reason} -> Mix.raise(faucet_refusal_text(reason))
    end
  end

  defp accept_faucet!(body) do
    if LighterProvision.faucet_ok?(body) do
      Mix.shell().info("faucet: #{Jason.encode!(body)}")
    else
      Mix.raise(faucet_refusal_text(body))
    end
  end

  defp wait_for_account!(config) do
    url =
      config.base_url <>
        "/api/v1/accountsByL1Address?l1_address=" <> URI.encode_www_form(config.l1_address)

    case poll_account(url, 1) do
      {:ok, index} -> index
      :error -> Mix.raise(account_missing_text(config.l1_address))
    end
  end

  defp poll_account(_url, attempt) when attempt > @account_poll_attempts, do: :error

  defp poll_account(url, attempt) do
    case account_index_from(url) do
      {:ok, index} ->
        Mix.shell().info("account appeared: index=#{index} (attempt #{attempt})")
        {:ok, index}

      :retry ->
        Process.sleep(@account_poll_ms)
        poll_account(url, attempt + 1)
    end
  end

  defp account_index_from(url) do
    url
    |> get_json()
    |> account_index_result()
  end

  defp account_index_result({:ok, body}), do: account_index_or_retry(LighterProvision.parse_account_index(body))
  defp account_index_result({:error, _reason}), do: :retry

  defp account_index_or_retry({:ok, index}), do: {:ok, index}
  defp account_index_or_retry({:error, :account_not_found}), do: :retry

  defp next_nonce!(config, account_index) do
    url =
      config.base_url <>
        "/api/v1/nextNonce?account_index=#{account_index}&api_key_index=#{config.api_key_index}"

    case get_json(url) do
      {:ok, body} -> nonce_from_body!(body)
      {:error, reason} -> Mix.raise("Lighter nextNonce failed: #{inspect(reason)}")
    end
  end

  defp nonce_from_body!(body) do
    case LighterProvision.parse_nonce(body) do
      {:ok, nonce} -> nonce
      {:error, :nonce_not_found} -> Mix.raise("Lighter nextNonce did not return a nonce: #{inspect(body)}")
    end
  end

  defp sign_change_pub_key!(config, account_index, pub_key, signature, nonce) do
    credentials =
      Credentials.new!(
        api_key: Integer.to_string(config.api_key_index),
        secret: config.api_private_key,
        uid: Integer.to_string(account_index)
      )

    helper_config = %{
      base_url: config.base_url,
      testnet: config.chain_id == LighterProvision.testnet_chain_id(),
      chain_id: config.chain_id,
      helper_path: helper_path()
    }

    params = %{
      pub_key: pub_key,
      l1_signature: signature,
      skip_nonce: false,
      nonce: nonce
    }

    result = Lighter.sign_transaction(:change_pub_key, params, credentials, helper_config)
    _ = Lighter.terminate_helper(credentials, helper_config)
    signed_transaction!(result)
  end

  defp signed_transaction!({:ok, transaction}), do: transaction
  defp signed_transaction!({:error, reason}), do: Mix.raise("ChangePubKey signing failed: #{inspect(reason)}")

  defp send_tx!(config, transaction) do
    url = config.base_url <> "/api/v1/sendTx"
    body = URI.encode_query(%{"tx_type" => transaction.tx_type, "tx_info" => transaction.tx_info})

    case post_form(url, body) do
      {:ok, response} -> accept_send_tx!(response)
      {:error, reason} -> Mix.raise("Lighter sendTx failed: #{inspect(reason)}")
    end
  end

  defp accept_send_tx!(body) do
    if LighterProvision.code_ok?(body) do
      Mix.shell().info("sendTx: #{Jason.encode!(body)}")
    else
      Mix.raise("Lighter sendTx refused ChangePubKey: #{inspect(body)}")
    end
  end

  defp verify_registration!(config, account_index, pub_key, nonce_before) do
    registered = wait_for_api_key!(config, account_index)
    expected = LighterProvision.normalize_pub_key(pub_key)

    if registered != expected do
      Mix.raise("registered public_key #{registered} does not equal derived #{expected}")
    end

    nonce_after = next_nonce!(config, account_index)

    if nonce_after <= nonce_before do
      Mix.raise("nextNonce #{nonce_after} did not advance past #{nonce_before}")
    end

    Mix.shell().info("apikeys public_key=#{registered} nextNonce=#{nonce_after}")
    :ok
  end

  defp wait_for_api_key!(config, account_index) do
    url =
      config.base_url <>
        "/api/v1/apikeys?account_index=#{account_index}&api_key_index=#{config.api_key_index}"

    case poll_api_key(url, config.api_key_index, 1) do
      {:ok, public_key} ->
        public_key

      :error ->
        Mix.raise(
          "GET /api/v1/apikeys did not return api_key_index=#{config.api_key_index} after " <>
            "#{@account_poll_attempts} polls"
        )
    end
  end

  defp poll_api_key(_url, _api_key_index, attempt) when attempt > @account_poll_attempts, do: :error

  defp poll_api_key(url, api_key_index, attempt) do
    case api_key_from(url, api_key_index) do
      {:ok, public_key} ->
        {:ok, public_key}

      :retry ->
        Process.sleep(@account_poll_ms)
        poll_api_key(url, api_key_index, attempt + 1)
    end
  end

  defp api_key_from(url, api_key_index) do
    url
    |> get_json()
    |> api_key_result(api_key_index)
  end

  defp api_key_result({:ok, body}, api_key_index),
    do: api_key_or_retry(LighterProvision.parse_api_key(body, api_key_index))

  defp api_key_result({:error, _reason}, _api_key_index), do: :retry

  defp api_key_or_retry({:ok, %{public_key: public_key}}), do: {:ok, public_key}
  defp api_key_or_retry({:error, :api_key_not_found}), do: :retry

  defp assert_signer!(l1_address, message, signature) do
    case LighterProvision.assert_signer(l1_address, message, signature) do
      :ok ->
        :ok

      {:error, {:signer_mismatch, recovered, expected}} ->
        Mix.raise(
          "L1 signature recovers #{recovered}, not the account l1_address #{expected}. " <>
            "Aborting before sendTx."
        )

      {:error, :invalid_signature} ->
        Mix.raise("L1 signature could not be recovered. Aborting before sendTx.")
    end
  end

  defp derive_pub_key!(api_private_key) do
    source_dir = BuildLighterSigner.source_dir()
    go = System.find_executable("go") || Mix.raise(go_missing_text())

    case System.cmd(go, ["run", "./cmd/derive_pubkey", api_private_key],
           cd: source_dir,
           stderr_to_stdout: true
         ) do
      {output, 0} -> accept_derived_pub_key!(output)
      {output, status} -> Mix.raise("derive_pubkey failed with status #{status}:\n#{output}")
    end
  end

  defp accept_derived_pub_key!(output) do
    pub_key = String.trim(output)

    if byte_size(pub_key) == 80 do
      pub_key
    else
      Mix.raise("derive_pubkey produced #{inspect(output)}; expected 80 hex characters")
    end
  end

  defp ensure_go! do
    case CheckLighterSigner.toolchain(&System.find_executable/1) do
      {:ok, _executables} -> :ok
      {:error, missing} -> Mix.raise(go_missing_text(missing))
    end
  end

  defp ensure_helper! do
    path = helper_path()

    if !File.regular?(path) do
      Mix.shell().info("Lighter helper missing at #{path}; building")
      Mix.Task.run("bourse.build_lighter_signer", [])
    end

    :ok
  end

  defp helper_path do
    BuildLighterSigner.host_target()
    |> BuildLighterSigner.output_dir()
    |> Path.join(BuildLighterSigner.executable_name(BuildLighterSigner.host_target()))
  end

  defp get_json(url) do
    case Req.get(url, receive_timeout: @req_receive_timeout_ms) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_form(url, body) do
    case Req.post(url,
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body: body,
           receive_timeout: @req_receive_timeout_ms
         ) do
      {:ok, %Req.Response{body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp flag_or_env!(opts, flag, env_var, missing_text) do
    case Keyword.get(opts, flag) || System.get_env(env_var) do
      value when is_binary(value) and value != "" -> value
      _missing -> Mix.raise(missing_text)
    end
  end

  defp integer_flag_or_env!(opts, flag, env_var, missing_text) do
    case Keyword.get(opts, flag) do
      value when is_integer(value) -> value
      nil -> parse_integer_env!(System.get_env(env_var), missing_text)
    end
  end

  defp parse_integer_env!(value, missing_text) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> Mix.raise(missing_text)
    end
  end

  defp parse_integer_env!(_value, missing_text), do: Mix.raise(missing_text)

  defp ensure_valid_args!([]), do: :ok
  defp ensure_valid_args!(invalid), do: Mix.raise("Invalid options: #{inspect(invalid)}")

  defp l1_missing_text do
    """
    Lighter testnet provisioning needs an L1 address and private key.

    Pass flags:
      mix bourse.provision_lighter --l1-address 0x… --l1-private-key 0x…

    Or export:
      export LIGHTER_TESTNET_L1_ADDRESS=0x…
      export LIGHTER_TESTNET_L1_PRIVATE_KEY=0x…

    This mix task is the only place in the repo that reads those variables.
    The L1 key is an argument to ChangePubKey signing in Elixir; it is never
    stored on Bourse.Credentials and never sent to the native helper.
    """
  end

  defp api_missing_text do
    """
    Lighter testnet provisioning needs the zk API private key and key index.

    Pass flags:
      mix bourse.provision_lighter --api-private-key … --api-key-index 3

    Or export:
      export LIGHTER_TESTNET_API_PRIVATE_KEY=…
      export LIGHTER_TESTNET_API_KEY_INDEX=3
    """
  end

  defp go_missing_text(missing \\ ["go"]) do
    """
    Lighter testnet provisioning needs the Go toolchain (and a C compiler) to
    build the native signer and derive the zk public key.

    Missing: #{Enum.join(missing, ", ")}.

    Install Go 1.25+ and a C compiler, then:
      mix bourse.build_lighter_signer
    """
  end

  defp faucet_refusal_text(body) do
    """
    Lighter testnet faucet refused the request: #{inspect(body)}

    Re-run:
      mix bourse.provision_lighter --l1-address 0x… --l1-private-key 0x…

    The faucet is GET #{LighterProvision.testnet_url()}/api/v1/faucet?l1_address=<addr>
    """
  end

  defp account_missing_text(l1_address) do
    """
    Lighter testnet account for #{l1_address} never appeared after
    #{@account_poll_attempts} polls of GET /api/v1/accountsByL1Address.

    Check the faucet response above, then retry:
      mix bourse.provision_lighter --l1-address #{l1_address} --l1-private-key 0x…
    """
  end
end
