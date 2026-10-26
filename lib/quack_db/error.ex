defmodule QuackDB.Error do
  @moduledoc """
  Structured error returned by the QuackDB client.

  When DuckDB returns an `errors_as_json` payload, `metadata` includes
  `:exception_type` and `:exception_message`. The original `message` is preserved,
  including any native-append prefix. QuackDB does not enable this server setting
  automatically or infer constraint names from error text.
  """

  @retriable_server_codes [:transaction_conflict, :connection_expired]
  @disconnect_server_codes [:connection_invalidated, :connection_expired]
  @expired_connection_messages [
    "Connection heartbeat lease expired",
    "Invalid connection id",
    "Connection does not exist / already disconnected"
  ]

  @type code :: atom()
  @type source :: :client | :server | :transport | :protocol

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          source: source(),
          retriable?: boolean(),
          query: iodata() | nil,
          connection_id: String.t() | nil,
          metadata: map()
        }

  defexception [:code, :message, :source, :retriable?, :query, :connection_id, :metadata]

  @impl true
  def exception(options) do
    new(
      Keyword.fetch!(options, :code),
      Keyword.fetch!(options, :message),
      Keyword.take(options, [:source, :retriable?, :query, :connection_id, :metadata])
    )
  end

  @spec new(code(), String.t(), Keyword.t()) :: t()
  def new(code, message, options \\ []) do
    %__MODULE__{
      code: code,
      message: message,
      source: Keyword.get(options, :source, :client),
      retriable?: Keyword.get(options, :retriable?, false),
      query: Keyword.get(options, :query),
      connection_id: Keyword.get(options, :connection_id),
      metadata: Keyword.get(options, :metadata, %{})
    }
  end

  @doc """
  Builds a server error from a Quack error response or a bare message.

  The code is `:query_cancelled`, `:transaction_conflict`,
  `:connection_expired`, `:connection_invalidated`, or `:server_error`.
  """
  @spec server(struct() | String.t()) :: t()
  def server(%QuackDB.Protocol.Message.ErrorResponse{} = response) do
    metadata =
      response.message
      |> server_metadata()
      |> put_exception_type(response.exception_type)
      |> put_extra_info(response.extra_info)
      |> put_must_invalidate(response.must_invalidate)

    code = server_code(response, metadata)

    new(code, response.message,
      source: :server,
      retriable?: code in @retriable_server_codes,
      metadata: metadata
    )
  end

  def server(message) when is_binary(message) do
    server(%QuackDB.Protocol.Message.ErrorResponse{message: message})
  end

  @doc """
  Returns DuckDB's exception type for a server error, such as `"Catalog"` or
  `"Constraint"`, or `nil` when the error did not come from the server.
  """
  @spec exception_type(t()) :: String.t() | nil
  def exception_type(%__MODULE__{metadata: metadata}), do: Map.get(metadata, :exception_type)

  @doc """
  Returns whether the error means the server dropped the connection, so the
  client must reconnect: its heartbeat lease expired or its database died.
  """
  @spec disconnect?(t()) :: boolean()
  def disconnect?(%__MODULE__{code: code}), do: code in @disconnect_server_codes

  @impl true
  def message(%__MODULE__{} = error) do
    [
      error.message,
      query_message(error.query),
      connection_message(error.connection_id)
    ]
    |> IO.iodata_to_binary()
  end

  defp server_metadata(message) do
    with {:ok, decoded} when is_map(decoded) <- JSON.decode(message),
         {:ok, exception} <- QuackDB.Error.ServerException.from_map(decoded) do
      Map.from_struct(exception)
    else
      _ -> %{}
    end
  end

  defp put_exception_type(metadata, ""), do: metadata
  defp put_exception_type(metadata, type), do: Map.put(metadata, :exception_type, type)

  defp put_must_invalidate(metadata, true), do: Map.put(metadata, :must_invalidate, true)
  defp put_must_invalidate(metadata, _false), do: metadata

  defp put_extra_info(metadata, extra_info) when map_size(extra_info) == 0, do: metadata
  defp put_extra_info(metadata, extra_info), do: Map.put(metadata, :extra_info, extra_info)

  defp server_code(%{must_invalidate: true}, _metadata), do: :connection_invalidated

  defp server_code(%{message: message} = response, metadata) do
    cond do
      message in @expired_connection_messages ->
        :connection_expired

      String.downcase(response.exception_type) == "interrupt" ->
        :query_cancelled

      transaction_conflict?(Map.get(metadata, :exception_message, message)) ->
        :transaction_conflict

      true ->
        :server_error
    end
  end

  defp query_message(nil), do: []
  defp query_message(query), do: ["\n\n    query: ", query]

  defp connection_message(nil), do: []
  defp connection_message(connection_id), do: ["\n    connection_id: ", connection_id]

  defp transaction_conflict?("Conflict on " <> _rest), do: true
  defp transaction_conflict?(message), do: String.contains?(message, "Transaction conflict")
end

defimpl Inspect, for: QuackDB.Error do
  import Inspect.Algebra

  alias QuackDB.Inspect, as: QuackInspect

  def inspect(error, opts) do
    fields = [
      code: error.code,
      source: error.source,
      message: QuackInspect.truncate(error.message),
      query: QuackInspect.truncate(error.query),
      connection_id: QuackInspect.short_id(error.connection_id),
      retriable?: error.retriable?
    ]

    concat(QuackInspect.container("QuackDB.Error", fields, opts))
  end
end
