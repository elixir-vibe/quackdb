defmodule QuackDB.Error do
  @moduledoc """
  Structured error returned by the QuackDB client.
  """

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

  @doc false
  @spec server(String.t()) :: t()
  def server(message) when is_binary(message) do
    if transaction_conflict?(message) do
      new(:transaction_conflict, message, source: :server, retriable?: true)
    else
      new(:server_error, message, source: :server)
    end
  end

  @impl true
  def message(%__MODULE__{} = error) do
    [
      error.message,
      query_message(error.query),
      connection_message(error.connection_id)
    ]
    |> IO.iodata_to_binary()
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
