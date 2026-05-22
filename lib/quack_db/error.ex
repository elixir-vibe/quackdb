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
          metadata: map()
        }

  defexception [:code, :message, :source, :retriable?, :metadata]

  @impl true
  def exception(options) do
    new(
      Keyword.fetch!(options, :code),
      Keyword.fetch!(options, :message),
      Keyword.take(options, [:source, :retriable?, :metadata])
    )
  end

  @spec new(code(), String.t(), Keyword.t()) :: t()
  def new(code, message, options \\ []) do
    %__MODULE__{
      code: code,
      message: message,
      source: Keyword.get(options, :source, :client),
      retriable?: Keyword.get(options, :retriable?, false),
      metadata: Keyword.get(options, :metadata, %{})
    }
  end
end
