defmodule QuackDB.Binary do
  @moduledoc """
  Downloads and locates a DuckDB executable for local `QuackDB.Server` usage.

  This is an explicit helper: QuackDB will not download executables unless you
  call `install/1`, `install!/1`, `path/1`, run the install Mix task, or start
  `QuackDB.Server` with `duckdb: :managed`.

  Set `QUACKDB_BINARY_PATH` to force a system or custom executable. Set
  `QUACKDB_BINARY_CACHE_DIR` or pass `:cache_dir` to choose where managed
  downloads are stored.
  """

  alias QuackDB.Error

  @default_version "1.5.3"
  @default_base_url "https://install.duckdb.org"
  @probe_sql "SELECT 2*3*7"

  @type option ::
          {:path, Path.t()}
          | {:version, String.t()}
          | {:base_url, String.t()}
          | {:cache_dir, Path.t()}
          | {:sha256, String.t()}
          | {:force, boolean()}

  @doc "Returns a path to a usable DuckDB binary, downloading it when needed."
  @spec path([option()]) :: {:ok, Path.t()} | {:error, Error.t()}
  def path(options \\ []) do
    case Keyword.get(options, :path) || System.get_env("QUACKDB_BINARY_PATH") do
      path when is_binary(path) and path != "" -> validate_binary(Path.expand(path))
      _missing -> install(options)
    end
  end

  @doc "Like `path/1`, but raises on failure."
  @spec path!([option()]) :: Path.t()
  def path!(options \\ []) do
    case path(options) do
      {:ok, path} -> path
      {:error, error} -> raise error
    end
  end

  @doc "Downloads DuckDB CLI for the current OS/architecture unless already cached."
  @spec install([option()]) :: {:ok, Path.t()} | {:error, Error.t()}
  def install(options \\ []) do
    with {:ok, target} <- target(),
         {:ok, path} <- cached_path(target, options),
         :ok <- maybe_download(path, target, options),
         :ok <- validate_binary(path) |> result_to_ok() do
      {:ok, path}
    end
  end

  @doc "Like `install/1`, but raises on failure."
  @spec install!([option()]) :: Path.t()
  def install!(options \\ []) do
    case install(options) do
      {:ok, path} -> path
      {:error, error} -> raise error
    end
  end

  defp maybe_download(path, _target, options) do
    if File.exists?(path) and not Keyword.get(options, :force, false) do
      :ok
    else
      download(path, options)
    end
  end

  defp download(path, options) do
    with {:ok, target} <- target(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, compressed} <- fetch(download_url(target, options)),
         :ok <- verify_checksum(compressed, options),
         {:ok, binary} <- gunzip(compressed),
         :ok <- File.write(path, binary),
         :ok <- File.chmod(path, 0o755) do
      :ok
    end
  end

  defp fetch(url) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    http_options = [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]
    options = [body_format: :binary]

    case :httpc.request(:get, {String.to_charlist(url), []}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _headers, body}} ->
        error(:download_failed, "DuckDB download returned HTTP #{status}", %{url: url, body: body})

      {:error, reason} ->
        error(:download_failed, "DuckDB download failed: #{inspect(reason)}", %{
          url: url,
          reason: reason
        })
    end
  end

  defp gunzip(compressed) do
    {:ok, :zlib.gunzip(compressed)}
  rescue
    error -> error(:archive_error, "failed to unpack DuckDB binary: #{Exception.message(error)}")
  end

  defp verify_checksum(binary, options) do
    case Keyword.get(options, :sha256) do
      nil -> :ok
      expected -> compare_checksum(binary, expected)
    end
  end

  defp compare_checksum(binary, expected) do
    actual = :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

    if String.downcase(expected) == actual do
      :ok
    else
      error(:checksum_mismatch, "DuckDB download checksum mismatch", %{
        expected: expected,
        actual: actual
      })
    end
  end

  defp validate_binary(path) do
    case System.cmd(path, ["-noheader", "-init", "/dev/null", "-csv", "-batch", "-s", @probe_sql],
           stderr_to_stdout: true
         ) do
      {"42\n", 0} ->
        {:ok, path}

      {"42\r\n", 0} ->
        {:ok, path}

      {output, status} ->
        error(:invalid_duckdb_binary, "DuckDB binary probe failed", %{
          path: path,
          output: output,
          status: status
        })
    end
  rescue
    error ->
      error(:invalid_duckdb_binary, "DuckDB binary probe failed: #{Exception.message(error)}", %{
        path: path
      })
  end

  defp result_to_ok({:ok, _path}), do: :ok
  defp result_to_ok({:error, error}), do: {:error, error}

  defp download_url(target, options) do
    base_url = options |> Keyword.get(:base_url, @default_base_url) |> String.trim_trailing("/")
    version = Keyword.get(options, :version, @default_version)
    "#{base_url}/v#{version}/duckdb_cli-#{target}.gz"
  end

  defp cached_path(target, options) do
    version = Keyword.get(options, :version, @default_version)
    {:ok, Path.expand(Path.join([cache_dir(options), version, target, executable_name()]))}
  end

  defp cache_dir(options) do
    Keyword.get(options, :cache_dir) || System.get_env("QUACKDB_BINARY_CACHE_DIR") ||
      :filename.basedir(:user_cache, "quackdb/duckdb")
  end

  defp target do
    os = :os.type()
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    cond do
      os == {:unix, :darwin} and arch in ["aarch64-apple-darwin", "arm64-apple-darwin"] ->
        {:ok, "osx-arm64"}

      os == {:unix, :darwin} and arch == "x86_64-apple-darwin" ->
        {:ok, "osx-amd64"}

      match?({:unix, _}, os) and String.starts_with?(arch, "x86_64") ->
        {:ok, "linux-amd64"}

      match?({:unix, _}, os) and String.starts_with?(arch, "aarch64") ->
        {:ok, "linux-arm64"}

      true ->
        error(:unsupported_target, "unsupported DuckDB target #{inspect(os)} #{arch}")
    end
  end

  defp executable_name, do: "duckdb"

  defp error(code, message, metadata \\ %{}) do
    {:error, Error.new(code, message, source: :client, metadata: metadata)}
  end
end
