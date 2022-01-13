defmodule Elrondex.Transaction do
  alias Elrondex.{Transaction, Account, REST}

  @sign_fields [
    :nonce,
    :value,
    :receiver,
    :sender,
    :gasPrice,
    :gasLimit,
    :data,
    :chainID,
    :version
  ]
  @number_sign_fields [:nonce, :gasPrice, :gasLimit, :version]

  defstruct network: nil,
            account: nil,
            # Require signature fields in signature order
            # nonce signature field 1/9
            nonce: nil,
            # value signature field 2/9
            # TODO Do we store integer or string value ?
            value: nil,
            # receiver signature field 3/9
            receiver: nil,
            # sender signature field 4/9
            sender: nil,
            # gasPrice signature field 5/9, loaded from Network.erd_min_gas_price
            gasPrice: nil,
            # gasLimit signature field 6/9, loaded from Network.erd_min_gas_limit
            gasLimit: nil,
            # data signature field 7/9
            data: nil,
            # chainID signature field 8/9, loaded from Network.erd_chain_id
            chainID: nil,
            # version signature field 9/9, loaded from Network.erd_min_transaction_version
            version: nil,
            # Computed signature based on 1-9 signature fields
            signature: nil
  @doc """
  Defines a data structure for account details.
  Its arguments are load from account
  Eg transaction(account, reciver,value,data) or transaction(account)
  """
  def transaction(%Account{} = account, receiver, value, data \\ nil) do
    %Transaction{
      account: account,
      sender: account.address,
      receiver: receiver,
      value: value,
      data: data
    }
  end

  def to_signed_map(%Transaction{} = tr) do
    # Encode data as base64
    tr =
      case tr.data do
        nil -> tr
        _ -> %{tr | data: Base.encode64(tr.data)}
      end

    # Ensure value is returned as string
    tr =
      case tr.value do
        int_value when is_integer(int_value) -> %{tr | value: Integer.to_string(int_value)}
        _ -> tr
      end

    Enum.reduce([:signature | @sign_fields], %{}, fn f, acc -> Map.put(acc, f, Map.get(tr, f)) end)
  end
  @doc """
  Signs a transaction to be done.
  Its argument it's the transaction itself, then it calls data_to_sign(), signs and encrypts the result.
  """
  def sign(%Transaction{} = tr) do
    signature =
      tr
      |> data_to_sign()
      |> Account.sign(tr.account)
      |> Base.encode16(case: :lower)

    %{tr | signature: signature}
  end

  def sign_verify(%Transaction{} = tr, %Account{} = account) do
    data_to_sign(tr)
    |> Account.sign_verify(tr.signature, account)
  end

  def sign_verify(%Transaction{} = tr) do
    sign_verify(tr, Account.from_address(tr.sender))
  end

  def prepare(%Transaction{} = tr, network) do
    tr = %{
      tr
      | network: network,
        gasPrice: network.erd_min_gas_price,
        # Is calculated by prepare_gas_limit
        # gasLimit: network.erd_min_gas_limit,
        chainID: network.erd_chain_id,
        version: network.erd_min_transaction_version
    }

    with {:ok, sender_state} <- REST.get_address(network, tr.sender),
         {:ok, tr} <- prepare_nonce(tr, Map.get(sender_state, "nonce")),
         {:ok, tr} <- prepare_gas_limit(tr, network, Map.get(sender_state, "balance")) do
      tr
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # def prepare(%Transaction{} = tr, sender_state) when is_map(sender_state) do
  # end

  def prepare_nonce(%Transaction{} = tr, nonce) when is_integer(nonce) do
    {:ok, %{tr | nonce: nonce}}
  end

  def prepare_nonce(%Transaction{} = _tr, nonce) do
    {:error, {:invalid_nonce, nonce}}
  end

  # We calculate gasLimit only when is not calculated gasLimit: nil
  def prepare_gas_limit(%Transaction{gasLimit: nil} = tr, network, balance) do
    # TODO calculate gasLimit
    tr =
      case tr.data do
        nil ->
          %{tr | gasLimit: network.erd_min_gas_limit}

        data ->
          gas_limit = network.erd_min_gas_limit + byte_size(data) * network.erd_gas_per_data_byte
          %{tr | gasLimit: gas_limit}
      end

    {:ok, tr}
  end

  def prepare_gas_limit(%Transaction{} = tr, _network, _balance) do
    {:ok, tr}
  end

  def sign_fields, do: @sign_fields

  def sign_field_type(field) when field in @number_sign_fields, do: :number
  def sign_field_type(_), do: :string

  # TODO, is not used
  def is_required_sign_field(:data), do: false
  def is_required_sign_field(field) when field in @sign_fields, do: true
  def is_required_sign_field(_), do: false

  def data_to_sign(tr) do
    json_to_sign =
      @sign_fields
      |> Enum.map(fn field -> prepare_sign_field(tr, field) end)
      |> Enum.filter(fn value -> value != nil end)
      |> Enum.join(",")

    "{#{json_to_sign}}"
  end

  def prepare_sign_field(tr, field) do
    value = Map.get(tr, field)

    case {field, sign_field_type(field)} do
      {:data, _} -> prepare_sign_field_base64(field, value)
      {_, :string} -> prepare_sign_field_string(field, value)
      {_, :number} -> prepare_sign_field_number(field, value)
    end
  end

  def prepare_sign_field_base64(field, value) do
    case value do
      nil -> nil
      "" -> nil
      data -> prepare_sign_field_string(field, Base.encode64(data))
    end
  end

  def prepare_sign_field_string(field, value) do
    case value do
      nil -> nil
      "" -> nil
      data -> "\"#{field}\":\"#{data}\""
    end
  end

  def prepare_sign_field_number(field, value) do
    case value do
      nil -> nil
      "" -> nil
      data when is_integer(data) -> "\"#{field}\":#{data}"
      _ -> nil
    end
  end
end
