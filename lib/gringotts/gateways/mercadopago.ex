defmodule Gringotts.Gateways.Mercadopago do
  @moduledoc """
  [mercadopago][home] gateway implementation.

  For reference see [mercadopago documentation][docs].

  The following features of mercadopago are implemented:

  | Action                       | Method        | 
  | ------                       | ------        | 
  | Pre-authorize                | `authorize/3` | 
  | Capture                      | `capture/3`   |
  | Purchase                     | `purchase/3`  |
  | Reversal                     | `void/2`      |
  | Refund                       | `refund/3`    |

  [home]: https://www.mercadopago.com/
  [docs]: https://www.mercadopago.com.ar/developers/en/api-docs/

  ## The `opts` argument

  Most `Gringotts` API calls accept an optional `keyword` list `opts` to supply
  optional arguments for transactions with the mercadopago
  gateway. The following keys are supported:

  | Key                      | Remark                                                                                  |
  | ----                     | ---                                                                                     |
  | `email`                  | Email of the customer. Type - string .                                                  |
  | `order_id`               | Order id issued by the merchant. Type- integer.                                         |
  | `payment_method_id`      | Payment network operators, eg. `visa`, `mastercard`. Type- string.                      |
  | `customer_id`            | Unique customer id issued by the gateway. For new customer it must be nil. Type- string |  

  ## Registering your mercadopago account at `Gringotts`

  After [making an account on mercadopago][credentials], head to the credentials and find
  your account "secrets" in the `Checkout Transparent`.

  | Config parameter | MERCADOPAGO secret |
  | -------          | ----               |
  | `:access_token`  | **Access Token**   |
  | `:public_key`    | **Public Key**     |

  > Your Application config **must include the `[:public_key, :access_token]` field(s)** and would look
  > something like this:
  > 
  >     config :gringotts, Gringotts.Gateways.Mercadopago,
  >         public_key: "your_secret_public_key"
  >         access_token: "your_secret_access_token"

  [credentials]: https://www.mercadopago.com/mlb/account/credentials?type=basic

  ## Note

  mercadopago processes money with upto two decimal places.

  ## Supported currencies and countries

  mercadopago supports the currencies listed [here][currencies].

  [currencies]: https://api.mercadopago.com/currencies  

  ## Following the examples

  1. First, set up a sample application and configure it to work with MERCADOPAGO.
  - You could do that from scratch by following our [Getting Started][gs] guide.
      - To save you time, we recommend [cloning our example
      repo][example] that gives you a pre-configured sample app ready-to-go.
          + You could use the same config or update it the with your "secrets"
          as described [above](#module-registering-your-mercadopago-account-at-gringotts).

  2. Run an `iex` session with `iex -S mix` and add some variable bindings :
  ```
  iex> card = %CreditCard{first_name: "John", last_name: "Doe", number: "4509953566233704", year: 2099, month: 12, verification_code: "123", brand: "VISA"}
  ```

  We'll be using these in the examples below.

  [gs]: https://github.com/aviabird/gringotts/wiki/
  [home]: https://www.mercadopago.com
  [example]: https://github.com/aviabird/gringotts_example
  """

  # The Base module has the (abstract) public API, and some utility
  # implementations.  
  @base_url "https://api.mercadopago.com"
  use Gringotts.Gateways.Base
  alias Gringotts.CreditCard
  # The Adapter module provides the `validate_config/1`
  # Add the keys that must be present in the Application config in the
  # `required_config` list
  use Gringotts.Adapter, required_config: [:public_key, :access_token]

  import Poison, only: [decode: 1]

  alias Gringotts.{CreditCard, Response}

  @doc """
  Transfers `amount` from the customer to the merchant.

  mercadopago attempts to process a purchase on behalf of the customer, by
  debiting `amount` from the customer's account by charging the customer's
  `card`.

  ## Example

  The following example shows how one would process a payment worth 42 BRL in
  one-shot, without (pre) authorization.

      iex> amount = Money.new(42, :BRL)
      iex> card = %Gringotts.CreditCard{first_name: "Harry", last_name: "Potter", number: "4200000000000000", year: 2099, month: 12, verification_code:  "123", brand: "VISA"}
      iex> {:ok, purchase_result} = Gringotts.purchase(Gringotts.Gateways.Mercadopago, amount, card, opts)
      iex> purchase_result.token # This is the customer ID/token

  """
  @spec purchase(Money.t(), CreditCard.t(), keyword) :: {:ok | :error, Response}
  def purchase(amount, %CreditCard{} = card, opts) do
    if Keyword.has_key?(opts, :customer_id) do
      auth_token(amount, card, opts, opts[:customer_id], true)
    else
      {state, res} = create_customer(opts)

      if state == :error do
        {state, res}
      else
        auth_token(amount, card, opts, res, true)
      end
    end
  end

  @doc """
  Refunds the `amount` to the customer's account with reference to a prior transfer.

  mercadopago processes a full or partial refund worth `amount`, referencing a
  previous `purchase/3` or `capture/3`.

  ## Note

  > You must have enough available money in your account so you can refund the payment amount successfully. Otherwise, you'll get a 400 Bad Request error.

  > You can refund a payment within 90 days after it was accredited.

  > You can only refund approved payments.

  > You can perform up to 20 partial refunds in one payment.

  ## Example

  The following example shows how one would (completely) refund a previous
  purchase (and similarily for captures).

      iex> amount = Money.new(35, :BRL)
      iex> {:ok, refund_result} = Gringotts.refund(Gringotts.Gateways.Mercadopago, purchase_result.id, amount)
  """
  @spec refund(Money.t(), String.t(), keyword) :: {:ok | :error, Response}
  def refund(payment_id, amount, opts) do
    {_, value, _, _} = Money.to_integer_exp(amount)

    # url = "#{@base_url}/v1/payments/#{payment_id}/refunds?access_token=#{opts[:config][:access_token]}"
    url_params = [access_token: opts[:config][:access_token]]
    body = %{amount: value} |> Poison.encode!()
    commit(:post, "/v1/payments/#{payment_id}/refunds", body, opts, params: url_params)
  end

  ###############################################################################
  #                                PRIVATE METHODS                              #
  ###############################################################################

  # Makes the request to mercadopago's network.
  # For consistency with other gateway implementations, make your (final)
  # network request in here, and parse it using another private method called
  # `respond`.
  @spec commit(atom, String.t(), String.t(), keyword, keyword) :: {:ok | :error, Response.t()}
  defp commit(method, path, body, opts, url_params) do
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    HTTPoison.request(method, "#{@base_url}#{path}", body, headers, url_params) |> respond(opts)
  end

  # Parses mercadopago's response and returns a `Gringotts.Response` struct
  # in a `:ok`, `:error` tuple.

  defp auth_token(amount, %CreditCard{} = card, opts, customer_id, capture) do
    opts = opts ++ [customer_id: customer_id]
    {state, res} = create_token(card, opts)

    if state == :error do
      {state, res}
    else
      auth(amount, card, opts, res, capture)
    end
  end

  defp auth(amount, %CreditCard{} = card, opts, token_id, capture) do
    {_, value, _, _} = Money.to_integer_exp(amount)
    opts = opts ++ [token_id: token_id]
    url_params = [access_token: opts[:config][:access_token]]

    body =
      authorize_params(value, card, opts, opts[:token_id], opts[:customer_id], capture)
      |> Poison.encode!()

    commit(:post, "/v1/payments", body, opts, params: url_params)
  end

  defp create_customer(opts) do
    url_params = [access_token: opts[:config][:access_token]]
    body = %{email: opts[:email]} |> Poison.encode!()

    {state, res} = commit(:post, "/v1/customers", body, opts, params: url_params)

    if state == :error do
      {state, res}
    else
      {state, res.id}
    end
  end

  defp token_params(%CreditCard{} = card) do
    %{
      expirationYear: card.year,
      expirationMonth: card.month,
      cardNumber: card.number,
      securityCode: card.verification_code,
      cardholder: %{name: CreditCard.full_name(card)}
    }
  end

  defp create_token(%CreditCard{} = card, opts) do
    url_params = [public_key: opts[:config][:public_key]]
    body = token_params(card) |> Poison.encode!()

    {state, res} =
      commit(:post, "/v1/card_tokens/#{opts[:customer_id]}", body, opts, params: url_params)

    case state do
      :error -> {state, res}
      _ -> {state, res.id}
    end
  end

  defp authorize_params(value, %CreditCard{} = card, opts, token_id, customer_id, capture) do
    %{
      payer: %{
        type: "customer",
        id: customer_id,
        first_name: card.first_name,
        last_name: card.last_name
      },
      order: %{
        type: "mercadopago",
        id: opts[:order_id]
      },
      installments: opts[:installments] || 1,
      transaction_amount: value,
      payment_method_id: String.downcase(card.brand),
      token: token_id,
      capture: capture
    }
  end

  defp success_body(body, status_code, opts) do
    %Response{
      success: true,
      id: body["id"],
      token: opts[:customer_id],
      status_code: status_code,
      message: body["status"]
    }
  end

  defp error_body(body, status_code, opts) do
    %Response{
      success: false,
      token: opts[:customer_id],
      status_code: status_code,
      message: body["message"]
    }
  end

  defp respond({:ok, %HTTPoison.Response{body: body, status_code: status_code}}, opts) do
    body = body |> Poison.decode!()

    case body["cause"] do
      nil -> {:ok, success_body(body, status_code, opts)}
      _ -> {:error, error_body(body, status_code, opts)}
    end
  end

  defp respond({:error, %HTTPoison.Error{} = error}, _) do
    {
      :error,
      Response.error(
        reason: "network related failure",
        message: "HTTPoison says '#{error.reason}' [ID: #{error.id || "nil"}]"
      )
    }
  end
end
