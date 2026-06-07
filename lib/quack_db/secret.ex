defmodule QuackDB.Secret do
  @moduledoc """
  SQL builders for DuckDB secrets.

  DuckDB uses secrets to configure access to HTTP endpoints, object stores, and
  cloud filesystems. These helpers build `CREATE SECRET` statements with
  QuackDB's SQL literal formatting so credentials and scopes are escaped
  consistently.

      alias QuackDB.Secret

      Secret.create(:s3, provider: :credential_chain, scope: "s3://bucket/prefix/")
      Secret.create(:http, name: :api, bearer_token: token)

  Atom values are emitted as DuckDB identifiers, which is useful for options
  such as `PROVIDER credential_chain`. String values are emitted as SQL string
  literals.
  """

  alias QuackDB.Error
  alias QuackDB.SQL

  @type secret_type :: :http | :s3 | :r2 | :gcs | :azure | :huggingface | String.t()
  @type option_value :: SQL.parameter() | atom() | map()

  @doc "Builds a DuckDB `CREATE SECRET` statement."
  @spec create(secret_type(), keyword(option_value())) :: iodata()
  def create(type, options \\ []) when is_list(options) do
    {name, options} = Keyword.pop(options, :name)
    {replace?, options} = Keyword.pop(options, :replace, true)
    {temporary?, options} = Keyword.pop(options, :temporary, false)

    [
      "CREATE ",
      if(replace?, do: "OR REPLACE ", else: []),
      if(temporary?, do: "TEMPORARY ", else: []),
      "SECRET ",
      secret_name(name),
      "(",
      secret_options(Keyword.put_new(options, :type, type)),
      ");"
    ]
  end

  defp secret_name(nil), do: []
  defp secret_name(name), do: [identifier!(name, :secret), " "]

  defp secret_options(options) do
    options
    |> Enum.map(fn {name, value} -> [option_name(name), " ", option_value(value)] end)
    |> Enum.intersperse(", ")
  end

  defp option_name(:type), do: "TYPE"
  defp option_name(name) when is_atom(name), do: name |> Atom.to_string() |> option_name()

  defp option_name(name) when is_binary(name) do
    name
    |> String.upcase()
    |> identifier!(:option)
  end

  defp option_name(name), do: invalid_identifier!(name, :option)

  defp option_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    identifier!(value, :value)
  end

  defp option_value(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, entry_value} ->
        [literal_key(key), ": ", option_value(entry_value)]
      end)
      |> Enum.intersperse(", ")

    ["MAP {", entries, "}"]
  end

  defp option_value(value), do: literal!(value)

  defp literal_key(key) when is_atom(key), do: key |> Atom.to_string() |> literal_key()
  defp literal_key(key) when is_binary(key), do: ["'", String.replace(key, "'", "''"), "'"]

  defp literal!(value) do
    case SQL.literal(value) do
      {:ok, literal} -> literal
      {:error, %Error{} = error} -> raise error
    end
  end

  defp identifier!(value, kind) do
    if QuackDB.Identifier.valid?(value) do
      to_string(value)
    else
      invalid_identifier!(value, kind)
    end
  end

  defp invalid_identifier!(value, kind) do
    raise ArgumentError, "invalid DuckDB secret #{kind} identifier: #{inspect(value)}"
  end
end
