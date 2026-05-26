defmodule Mix.Tasks.Quackdb.Install do
  @moduledoc """
  Downloads DuckDB's official CLI binary for local QuackDB servers.

      mix quackdb.install
      mix quackdb.install --version 1.5.3 --force
      mix quackdb.install --print-path

  The binary is cached under the user's cache directory by default. Set
  `QUACKDB_BINARY_CACHE_DIR` or pass `--cache-dir` to choose another location.
  """

  use Mix.Task

  @shortdoc "Downloads a DuckDB CLI binary for QuackDB.Server"

  @impl Mix.Task
  def run(args) do
    {options, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          version: :string,
          base_url: :string,
          cache_dir: :string,
          sha256: :string,
          force: :boolean,
          print_path: :boolean
        ],
        aliases: [p: :print_path]
      )

    case invalid do
      [] -> install(options)
      invalid -> Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp install(options) do
    Mix.Task.run("app.start")

    case QuackDB.Binary.install(options) do
      {:ok, path} -> report_path(path, options)
      {:error, error} -> Mix.raise(Exception.message(error))
    end
  end

  defp report_path(path, options) do
    if Keyword.get(options, :print_path, false) do
      Mix.shell().info(path)
    else
      Mix.shell().info("DuckDB installed at #{path}")
    end
  end
end
