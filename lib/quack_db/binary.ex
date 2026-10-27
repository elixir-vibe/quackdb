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

  @default_version "2.0.0"
  @default_base_url "https://install.duckdb.org"
  @probe_sql "SELECT version()"
  @checksums %{
    {"2.0.0", "linux-amd64"} =>
      "c6507206baf7793c6013dbd82368469a45f20dc0e17a6f92f204602f652ed2bc",
    {"2.0.0", "linux-amd64-musl"} =>
      "3285e4083a79955b0606ab799ebc1493087307cdc76b4827308b1a4dcdb371c9",
    {"2.0.0", "linux-arm64"} =>
      "859e1875d2a9515fbb4bf8871061437a14af82320da68c753f094c4b776348fe",
    {"2.0.0", "linux-arm64-musl"} =>
      "59aee3049c335917307f5df1b3722af1335fef99199dc89e8064d1b2838620c7",
    {"2.0.0", "osx-amd64"} => "fbc7013ba09d117396dabf16783281c2add47fc01cdac4855464a03526dc96ee",
    {"2.0.0", "osx-arm64"} => "188a36fe8883ef52e69165a0cbb6031ef679c8e6c448a1ce22951964149b7f96",
    {"2.0.0", "osx-universal"} =>
      "8a8f67e7c7f7d1392fa63ba3971948391392fe2a25fca63e7008e33c50beb4c2"
  }
  @targets @checksums
           |> Enum.map(fn {{_version, target}, _checksum} -> target end)
           |> Enum.uniq()
           |> Enum.sort()

  @type option ::
          {:path, Path.t()}
          | {:version, String.t()}
          | {:target, String.t()}
          | {:base_url, String.t()}
          | {:cache_dir, Path.t()}
          | {:sha256, String.t()}
          | {:force, boolean()}

  @doc "Returns QuackDB's pinned DuckDB CLI version for managed downloads."
  @spec default_version() :: String.t()
  def default_version, do: @default_version

  @doc "Returns known `{version, target}` checksum pairs for managed downloads."
  @spec known_targets() :: [{String.t(), String.t()}]
  def known_targets do
    @checksums |> Map.keys() |> Enum.sort()
  end

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
    with {:ok, target} <- target(options),
         {:ok, path} <- cached_path(target, options),
         :ok <- maybe_download(path, target, options),
         :ok <- maybe_validate_binary(path, target) do
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
    with {:ok, target} <- target(options),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, archive} <- fetch(download_url(target, options)),
         :ok <- verify_checksum(archive, target, options),
         {:ok, binary} <- extract(archive) do
      write_executable(path, binary)
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

  # DuckDB 2.0 ships the CLI as a gzipped tarball holding a single `duckdb`.
  defp extract(archive) do
    case :erl_tar.extract({:binary, archive}, [:compressed, :memory]) do
      {:ok, files} ->
        case List.keyfind(files, ~c"duckdb", 0) do
          {_name, binary} -> {:ok, binary}
          nil -> error(:archive_error, "DuckDB archive does not contain a duckdb executable")
        end

      {:error, reason} ->
        error(:archive_error, "failed to unpack DuckDB binary: #{inspect(reason)}")
    end
  end

  defp verify_checksum(binary, target, options) do
    version = Keyword.get(options, :version, @default_version)

    case Keyword.get(options, :sha256) || Map.get(@checksums, {version, target}) do
      nil ->
        error(
          :missing_checksum,
          "no checksum is known for DuckDB #{version} #{target}; pass :sha256 explicitly",
          %{
            version: version,
            target: target
          }
        )

      expected ->
        compare_checksum(binary, expected)
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

  # Concurrent installs must never expose a partial or open-for-write file at `path`:
  # executing a file that is open for writing fails with ETXTBSY, and so does opening a
  # running executable for writing. Write a private file and rename it into place, which
  # swaps the directory entry atomically and leaves already-running copies untouched.
  defp write_executable(path, binary) do
    tmp_path = "#{path}.#{System.pid()}-#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <- File.write(tmp_path, binary),
           :ok <- File.chmod(tmp_path, 0o755),
           :ok <- File.rename(tmp_path, path) do
        :ok
      else
        {:error, reason} ->
          error(
            :install_failed,
            "failed to install DuckDB binary: #{:file.format_error(reason)}",
            %{
              path: path,
              reason: reason
            }
          )
      end
    after
      # A no-op after a successful rename.
      File.rm(tmp_path)
    end
  end

  defp validate_binary(path) do
    args = ["-noheader", "-no-agent", "-init", "/dev/null", "-csv", "-batch", "-s", @probe_sql]

    case System.cmd(path, args, stderr_to_stdout: true) do
      {"v2." <> _rest, 0} ->
        {:ok, path}

      {output, 0} ->
        error(
          :unsupported_duckdb_version,
          "QuackDB requires DuckDB 2.0, got #{String.trim(output)}",
          %{
            path: path,
            output: output
          }
        )

      {output, status} ->
        error(
          :invalid_duckdb_binary,
          "DuckDB binary probe failed; QuackDB requires the DuckDB 2.0 CLI",
          %{
            path: path,
            output: output,
            status: status
          }
        )
    end
  rescue
    error in ErlangError ->
      error(:invalid_duckdb_binary, "DuckDB binary probe failed: #{Exception.message(error)}", %{
        path: path
      })
  end

  defp result_to_ok({:ok, _path}), do: :ok
  defp result_to_ok({:error, error}), do: {:error, error}

  defp download_url(target, options) do
    base_url = options |> Keyword.get(:base_url, @default_base_url) |> String.trim_trailing("/")
    version = Keyword.get(options, :version, @default_version)
    "#{base_url}/v#{version}/duckdb-cli-#{target}.tar.gz"
  end

  defp cached_path(target, options) do
    version = Keyword.get(options, :version, @default_version)
    {:ok, Path.expand(Path.join([cache_dir(options), version, target, executable_name()]))}
  end

  defp cache_dir(options) do
    Keyword.get(options, :cache_dir) || System.get_env("QUACKDB_BINARY_CACHE_DIR") ||
      :filename.basedir(:user_cache, "quackdb/duckdb")
  end

  defp maybe_validate_binary(path, target) do
    with {:ok, current_target} <- current_target() do
      if target == current_target do
        path |> validate_binary() |> result_to_ok()
      else
        :ok
      end
    end
  end

  defp target(options) do
    case Keyword.get(options, :target) do
      nil -> current_target()
      target when is_binary(target) -> validate_target(target)
    end
  end

  defp current_target do
    os = :os.type()
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    target_for_system(os, arch)
  end

  @doc false
  def target_for_system(os, arch) do
    linux_suffix = if String.ends_with?(arch, "-musl"), do: "-musl", else: ""

    cond do
      os == {:unix, :darwin} and String.starts_with?(arch, "aarch64-apple-darwin") ->
        {:ok, "osx-arm64"}

      os == {:unix, :darwin} and String.starts_with?(arch, "arm64-apple-darwin") ->
        {:ok, "osx-arm64"}

      os == {:unix, :darwin} and String.starts_with?(arch, "x86_64-apple-darwin") ->
        {:ok, "osx-amd64"}

      match?({:unix, _}, os) and String.starts_with?(arch, "x86_64") ->
        {:ok, "linux-amd64" <> linux_suffix}

      match?({:unix, _}, os) and String.starts_with?(arch, "aarch64") ->
        {:ok, "linux-arm64" <> linux_suffix}

      true ->
        error(
          :unsupported_target,
          "unsupported DuckDB binary target for #{inspect(os)} #{arch}; supported targets are #{Enum.join(@targets, ", ")}",
          %{os: os, arch: arch}
        )
    end
  end

  defp validate_target(target) do
    if target in @targets do
      {:ok, target}
    else
      error(
        :unsupported_target,
        "unsupported DuckDB binary target #{inspect(target)}; supported targets are #{Enum.join(@targets, ", ")}"
      )
    end
  end

  defp executable_name, do: "duckdb"

  defp error(code, message, metadata \\ %{}) do
    {:error, Error.new(code, message, source: :client, metadata: metadata)}
  end
end
