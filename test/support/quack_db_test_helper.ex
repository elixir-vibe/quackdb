defmodule QuackDB.TestHelper do
  @moduledoc false

  def unique_table(prefix) when is_binary(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  def create_table!(target, table, columns, options \\ []) do
    options = Keyword.put_new(options, :temporary, true)
    query!(target, QuackDB.DDL.create_table(table, columns, options))
  end

  def drop_table!(target, table) do
    query!(target, QuackDB.DDL.drop_table(table, if_exists: true))
  end

  def insert_rows!(target, table, rows, options \\ []) when is_list(rows) and is_list(options) do
    columns = Keyword.get(options, :columns)

    query!(target, [
      "INSERT INTO ",
      QuackDB.Type.quote_identifier(table),
      insert_columns(columns),
      " ",
      values(rows)
    ])
  end

  def query!(target, statement, params \\ []) do
    if repo?(target) do
      target.query!(statement, params)
    else
      QuackDB.query!(target, statement, params)
    end
  end

  def query(target, statement, params \\ []) do
    if repo?(target) do
      target.query(statement, params)
    else
      QuackDB.query(target, statement, params)
    end
  end

  def csv_file!(contents, prefix \\ "quackdb_csv") when is_binary(contents) do
    write_temp_file!(contents, prefix, ".csv")
  end

  def json_file!(contents, prefix \\ "quackdb_json") when is_binary(contents) do
    write_temp_file!(contents, prefix, ".json")
  end

  def csv_source!(contents, options \\ [header: true])
      when is_binary(contents) and is_list(options) do
    contents
    |> csv_file!()
    |> QuackDB.Source.csv(options)
  end

  def json_source!(contents, options \\ [format: :newline_delimited])
      when is_binary(contents) and is_list(options) do
    contents
    |> json_file!()
    |> QuackDB.Source.json(options)
  end

  defp repo?(target), do: is_atom(target) and function_exported?(target, :query!, 2)

  defp insert_columns(nil), do: []

  defp insert_columns(columns) when is_list(columns) do
    [
      " (",
      columns
      |> Enum.map(&QuackDB.Type.quote_identifier/1)
      |> Enum.intersperse(", "),
      ")"
    ]
  end

  defp values([]), do: raise(ArgumentError, "expected at least one row")

  defp values(rows) do
    [
      "VALUES ",
      rows
      |> Enum.map(&row/1)
      |> Enum.intersperse(", ")
    ]
  end

  defp row(values) when is_list(values) do
    [
      "(",
      values
      |> Enum.map(&literal!/1)
      |> Enum.intersperse(", "),
      ")"
    ]
  end

  defp row(value) do
    raise ArgumentError, "expected row as a list, got: #{inspect(value)}"
  end

  defp literal!(value) do
    case QuackDB.SQL.literal(value) do
      {:ok, literal} -> literal
      {:error, %QuackDB.Error{} = error} -> raise error
    end
  end

  defp write_temp_file!(contents, prefix, extension) do
    path =
      Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}#{extension}")

    File.write!(path, contents)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end
end
