defmodule QuackDB.Stage do
  @moduledoc """
  Temporarily exposes local files over HTTP for DuckDB source readers.

  Use this when Elixir can see a local file but the DuckDB Quack server cannot
  read that local path directly. The staged URL can be passed to
  `QuackDB.Source.csv/2`, `QuackDB.Source.parquet/2`, or other DuckDB source
  helpers that understand HTTP URLs.
  """

  @type staged_file :: %{
          url: String.t(),
          path: Path.t(),
          file_name: String.t(),
          token: String.t(),
          port: :inet.port_number()
        }

  @doc "Stages a local file for the duration of `fun`."
  @spec with_file(Path.t(), keyword(), (staged_file() -> term())) :: term()
  def with_file(path, options \\ [], fun) when is_function(fun, 1) do
    path = Path.expand(path)

    unless File.regular?(path) do
      raise ArgumentError, "expected a regular file to stage, got: #{inspect(path)}"
    end

    token = Keyword.get_lazy(options, :token, &random_token/0)
    file_name = Keyword.get(options, :file_name, Path.basename(path))
    scheme = Keyword.get(options, :scheme, "http")
    host = Keyword.get(options, :host, "127.0.0.1")
    port = Keyword.get(options, :port, 0)

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: listen_ip(host)
      ])

    {:ok, actual_port} = :inet.port(listen_socket)

    task =
      Task.async(fn ->
        serve_loop(listen_socket, path, token, file_name)
      end)

    staged = %{
      url: staged_url(scheme, host, actual_port, token, file_name),
      path: path,
      file_name: file_name,
      token: token,
      port: actual_port
    }

    try do
      fun.(staged)
    after
      :gen_tcp.close(listen_socket)
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp serve_loop(listen_socket, path, token, file_name) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        handle_socket(socket, path, token, file_name)
        serve_loop(listen_socket, path, token, file_name)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle_socket(socket, path, token, file_name) do
    with {:ok, request} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, requested_path} <- request_path(request),
         :ok <- authorize_path(requested_path, token, file_name),
         {:ok, stat} <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      :gen_tcp.send(socket, response_headers(200, stat.size, content_type(file_name)))
      stream_file(socket, file)
      File.close(file)
    else
      _error ->
        :gen_tcp.send(socket, response_headers(404, 0, "text/plain"))
    end

    :gen_tcp.close(socket)
  end

  defp request_path(request) do
    request
    |> String.split("\r\n", parts: 2)
    |> List.first()
    |> case do
      "GET " <> rest -> rest |> String.split(" ", parts: 2) |> List.first() |> normalize_path()
      "HEAD " <> rest -> rest |> String.split(" ", parts: 2) |> List.first() |> normalize_path()
      _other -> :error
    end
  end

  defp normalize_path(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) -> {:ok, path}
      _other -> :error
    end
  end

  defp authorize_path(path, token, file_name) do
    expected = "/#{token}/#{URI.encode(file_name)}"

    if URI.decode(path) == URI.decode(expected) do
      :ok
    else
      :error
    end
  end

  defp stream_file(socket, file) do
    case IO.binread(file, 64 * 1024) do
      data when is_binary(data) ->
        :gen_tcp.send(socket, data)
        stream_file(socket, file)

      :eof ->
        :ok
    end
  end

  defp response_headers(status, content_length, content_type) do
    reason = if status == 200, do: "OK", else: "Not Found"

    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason,
      "\r\ncontent-length: ",
      Integer.to_string(content_length),
      "\r\ncontent-type: ",
      content_type,
      "\r\nconnection: close\r\n\r\n"
    ]
  end

  defp staged_url(scheme, host, port, token, file_name) do
    URI.to_string(%URI{
      scheme: scheme,
      host: host,
      port: port,
      path: "/#{token}/#{URI.encode(file_name)}"
    })
  end

  defp listen_ip("127.0.0.1"), do: {127, 0, 0, 1}
  defp listen_ip("localhost"), do: {127, 0, 0, 1}
  defp listen_ip(_host), do: {127, 0, 0, 1}

  defp content_type(file_name) do
    case file_name |> Path.extname() |> String.downcase() do
      ".csv" -> "text/csv"
      ".json" -> "application/json"
      ".parquet" -> "application/octet-stream"
      _other -> "application/octet-stream"
    end
  end

  defp random_token do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
