defmodule QuackDB.Transport do
  @moduledoc false

  alias QuackDB.Error

  @type option :: {:timeout, timeout()} | {:req_options, Keyword.t()}

  @spec post(URI.t(), iodata(), [option]) :: {:ok, binary()} | {:error, Error.t()}
  def post(uri, body, options \\ []) do
    request_options = [
      url: URI.to_string(uri),
      body: IO.iodata_to_binary(body),
      headers: headers(),
      receive_timeout: Keyword.get(options, :timeout, 15_000)
    ]

    options
    |> Keyword.get(:req_options, [])
    |> Keyword.merge(request_options)
    |> Req.post()
    |> normalize_response()
  end

  defp headers do
    [
      {"content-type", "application/duckdb"},
      {"accept", "application/duckdb, application/vnd.duckdb, application/octet-stream"}
    ]
  end

  defp normalize_response({:ok, %{status: 200, body: body}}) when is_binary(body) do
    {:ok, body}
  end

  defp normalize_response({:ok, %{status: status, body: body}}) do
    message = "Quack server returned HTTP #{status}"

    {:error,
     Error.new(:http_error, message, source: :transport, metadata: %{body: body, status: status})}
  end

  defp normalize_response({:error, reason}) do
    {:error,
     Error.new(:transport_error, Exception.message(reason),
       source: :transport,
       metadata: %{reason: reason}
     )}
  end
end
