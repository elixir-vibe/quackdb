defmodule QuackDB.Storage.Segment do
  @moduledoc "A row from DuckDB's `pragma_storage_info` table function."

  defstruct [
    :row_group_id,
    :column_name,
    :column_id,
    :column_path,
    :segment_id,
    :segment_type,
    :start,
    :count,
    :compression,
    :stats,
    :has_updates,
    :persistent,
    :block_id,
    :block_offset,
    :segment_info,
    :additional_block_ids
  ]

  @type t :: %__MODULE__{
          row_group_id: integer() | nil,
          column_name: String.t() | nil,
          column_id: integer() | nil,
          column_path: String.t() | nil,
          segment_id: integer() | nil,
          segment_type: String.t() | nil,
          start: integer() | nil,
          count: integer() | nil,
          compression: String.t() | nil,
          stats: String.t() | nil,
          has_updates: boolean() | nil,
          persistent: boolean() | nil,
          block_id: integer() | nil,
          block_offset: integer() | nil,
          segment_info: String.t() | nil,
          additional_block_ids: term()
        }
end

defmodule QuackDB.Storage.DatabaseSize do
  @moduledoc "A row from DuckDB's `pragma_database_size` table function."

  defstruct [
    :database_name,
    :database_size,
    :block_size,
    :total_blocks,
    :used_blocks,
    :free_blocks,
    :wal_size,
    :memory_usage,
    :memory_limit
  ]

  @type t :: %__MODULE__{
          database_name: String.t() | nil,
          database_size: String.t() | nil,
          block_size: integer() | nil,
          total_blocks: integer() | nil,
          used_blocks: integer() | nil,
          free_blocks: integer() | nil,
          wal_size: String.t() | nil,
          memory_usage: String.t() | nil,
          memory_limit: String.t() | nil
        }
end

defmodule QuackDB.Storage.CompressionSummary do
  @moduledoc "Compression summary grouped by table column."

  defstruct source: nil, columns: %{}

  @type compression_stats :: %{
          segments: non_neg_integer(),
          values: non_neg_integer(),
          segment_types: %{String.t() => non_neg_integer()}
        }

  @type column_summary :: %{
          segments: non_neg_integer(),
          values: non_neg_integer(),
          compressions: %{String.t() => compression_stats()}
        }

  @type t :: %__MODULE__{
          source: String.t() | nil,
          columns: %{String.t() => column_summary()}
        }
end

defmodule QuackDB.Storage do
  @moduledoc """
  DuckDB storage observability helpers.

  The functions in this module wrap DuckDB's storage table functions and accept
  either a QuackDB connection or a QuackDB-backed Ecto repo. Table arguments may
  be schema modules, atoms, strings, or `{prefix, source}` tuples.
  """

  alias QuackDB.Storage.CompressionSummary
  alias QuackDB.Storage.DatabaseSize
  alias QuackDB.Storage.Segment

  @type source :: module() | atom() | String.t() | {atom() | String.t(), atom() | String.t()}

  @doc "Returns DuckDB storage segments for a table."
  @spec info(DBConnection.conn() | module(), source(), keyword()) ::
          {:ok, [Segment.t()]} | {:error, Exception.t()}
  def info(connection, source, options \\ []) do
    statement = QuackDB.SQL.call(:pragma_storage_info, [QuackDB.SourceRef.name(source)])

    with {:ok, result} <- QuackDB.query(connection, statement, [], options) do
      {:ok, QuackDB.ResultMapper.rows_to_structs(result, Segment)}
    end
  end

  @doc "Returns DuckDB storage segments for a table, raising on errors."
  @spec info!(DBConnection.conn() | module(), source(), keyword()) :: [Segment.t()]
  def info!(connection, source, options \\ []) do
    case info(connection, source, options) do
      {:ok, segments} -> segments
      {:error, error} -> raise error
    end
  end

  @doc "Returns compression usage grouped by table column."
  @spec compression(DBConnection.conn() | module(), source(), keyword()) ::
          {:ok, CompressionSummary.t()} | {:error, Exception.t()}
  def compression(connection, source, options \\ []) do
    with {:ok, segments} <- info(connection, source, options) do
      {:ok, compression_summary(QuackDB.SourceRef.name(source), segments)}
    end
  end

  @doc "Returns compression usage grouped by table column, raising on errors."
  @spec compression!(DBConnection.conn() | module(), source(), keyword()) ::
          CompressionSummary.t()
  def compression!(connection, source, options \\ []) do
    case compression(connection, source, options) do
      {:ok, summary} -> summary
      {:error, error} -> raise error
    end
  end

  @doc "Runs `CHECKPOINT` to flush the write-ahead log into the database file."
  @spec checkpoint(DBConnection.conn() | module(), keyword()) ::
          {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
  def checkpoint(connection, options \\ []) do
    QuackDB.query(connection, "CHECKPOINT", [], options)
  end

  @doc "Runs `CHECKPOINT`, raising on errors."
  @spec checkpoint!(DBConnection.conn() | module(), keyword()) :: QuackDB.Result.t()
  def checkpoint!(connection, options \\ []) do
    case checkpoint(connection, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc "Runs `FORCE CHECKPOINT` to wait for the checkpoint lock and flush storage."
  @spec force_checkpoint(DBConnection.conn() | module(), keyword()) ::
          {:ok, QuackDB.Result.t()} | {:error, Exception.t()}
  def force_checkpoint(connection, options \\ []) do
    QuackDB.query(connection, "FORCE CHECKPOINT", [], options)
  end

  @doc "Runs `FORCE CHECKPOINT`, raising on errors."
  @spec force_checkpoint!(DBConnection.conn() | module(), keyword()) :: QuackDB.Result.t()
  def force_checkpoint!(connection, options \\ []) do
    case force_checkpoint(connection, options) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc "Returns DuckDB database size information."
  @spec database_size(DBConnection.conn() | module(), keyword()) ::
          {:ok, [DatabaseSize.t()]} | {:error, Exception.t()}
  def database_size(connection, options \\ []) do
    with {:ok, result} <-
           QuackDB.query(connection, QuackDB.SQL.call(:pragma_database_size), [], options) do
      {:ok, QuackDB.ResultMapper.rows_to_structs(result, DatabaseSize)}
    end
  end

  @doc "Returns DuckDB database size information, raising on errors."
  @spec database_size!(DBConnection.conn() | module(), keyword()) :: [DatabaseSize.t()]
  def database_size!(connection, options \\ []) do
    case database_size(connection, options) do
      {:ok, sizes} -> sizes
      {:error, error} -> raise error
    end
  end

  defp compression_summary(source, segments) do
    columns =
      segments
      |> Enum.group_by(& &1.column_name)
      |> Map.new(fn {column_name, column_segments} ->
        {column_name, summarize_column(column_segments)}
      end)

    %CompressionSummary{source: source, columns: columns}
  end

  defp summarize_column(segments) do
    %{
      segments: length(segments),
      values: sum_counts(segments),
      compressions:
        segments
        |> Enum.group_by(&(&1.compression || "unknown"))
        |> Map.new(fn {compression, compression_segments} ->
          {compression,
           %{
             segments: length(compression_segments),
             values: sum_counts(compression_segments),
             segment_types: segment_type_counts(compression_segments)
           }}
        end)
    }
  end

  defp sum_counts(segments) do
    Enum.reduce(segments, 0, fn segment, total -> total + (segment.count || 0) end)
  end

  defp segment_type_counts(segments) do
    segments
    |> Enum.group_by(&(&1.segment_type || "unknown"))
    |> Map.new(fn {segment_type, entries} -> {segment_type, length(entries)} end)
  end
end
