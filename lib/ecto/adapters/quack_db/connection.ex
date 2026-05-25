if Code.ensure_loaded?(Ecto.Adapters.SQL.Connection) do
  defmodule Ecto.Adapters.QuackDB.Connection do
    @moduledoc """
    Ecto SQL connection callbacks backed by `QuackDB.DBConnection`.

    This module implements the raw query path used by
    `Ecto.Adapters.SQL.query/4` and `Repo.query/3`, plus read-oriented Ecto
    query generation for analytical DuckDB queries. Unsupported query features
    raise explicit errors instead of emitting partial SQL.
    """

    @behaviour Ecto.Adapters.SQL.Connection

    @impl true
    def child_spec(options) do
      {:ok, _} = Application.ensure_all_started(:db_connection)
      DBConnection.child_spec(QuackDB.DBConnection, options)
    end

    @impl true
    def prepare_execute(connection, name, statement, params, options) do
      ensure_list_params!(params)
      query = %QuackDB.Query{statement: IO.iodata_to_binary(statement)}

      case DBConnection.prepare_execute(
             connection,
             query,
             params,
             Keyword.put(options, :ecto_name, name)
           ) do
        {:ok, query, result} -> {:ok, query, normalize_result(result)}
        {:error, %QuackDB.Error{} = error} -> {:error, error}
        {:error, error} -> raise error
      end
    end

    @impl true
    def execute(connection, %QuackDB.Query{} = query, params, options) do
      ensure_list_params!(params)

      case DBConnection.execute(connection, query, params, options) do
        {:ok, query, result} -> {:ok, query, normalize_result(result)}
        {:error, %QuackDB.Error{} = error} -> {:error, error}
        {:error, error} -> raise error
      end
    end

    def execute(connection, statement, params, options)
        when is_binary(statement) or is_list(statement) do
      prepare_execute(connection, "", statement, params, options)
    end

    @impl true
    def query(connection, statement, params, options) do
      ensure_list_params!(params)

      case prepare_execute(connection, "", statement, params, options) do
        {:ok, _query, result} -> {:ok, result}
        {:error, error} -> {:error, error}
      end
    end

    @impl true
    def query_many(_connection, _statement, _params, _options) do
      unsupported!(:query_many, "multiple-result raw SQL is not supported yet")
    end

    @impl true
    def stream(connection, statement, params, options) do
      ensure_list_params!(params)

      DBConnection.stream(connection, %QuackDB.Query{statement: statement}, params, options)
      |> Stream.map(&normalize_result/1)
    end

    @impl true
    def to_constraints(_exception, _options), do: []

    @impl true
    def all(%Ecto.Query{} = query), do: Ecto.Adapters.QuackDB.Query.all(query)

    @impl true
    def update_all(_query),
      do:
        unsupported_iodata!(
          :schema_updates,
          "Ecto update_all is not supported yet; use Repo.query/3"
        )

    @impl true
    def delete_all(_query),
      do:
        unsupported_iodata!(
          :schema_deletes,
          "Ecto delete_all is not supported yet; use Repo.query/3"
        )

    @impl true
    def insert(prefix, table, header, rows, on_conflict, returning, placeholders) do
      [
        "INSERT INTO ",
        quote_table(prefix, table),
        insert_columns(header),
        " ",
        insert_rows(rows),
        on_conflict(on_conflict),
        returning(returning, placeholders)
      ]
    end

    @impl true
    def update(_prefix, _table, _fields, _filters, _returning) do
      unsupported_iodata!(:schema_updates, "Ecto updates are not supported yet; use Repo.query/3")
    end

    @impl true
    def delete(_prefix, _table, _filters, _returning) do
      unsupported_iodata!(:schema_deletes, "Ecto deletes are not supported yet; use Repo.query/3")
    end

    @impl true
    def explain_query(_connection, _query, _params, _options) do
      unsupported!(:explain, "Ecto explain is not supported yet")
    end

    @impl true
    def execute_ddl(_command) do
      unsupported_iodata!(
        :migrations,
        "Ecto migrations are not supported yet; use Repo.query/3 for raw SQL"
      )
    end

    @impl true
    def ddl_logs(_result), do: []

    @impl true
    def table_exists_query(table) do
      {"SELECT COUNT(*) FROM information_schema.tables WHERE table_name = ?", [table]}
    end

    defp ensure_list_params!(params) do
      unless is_list(params) do
        raise ArgumentError, "expected params to be a list, got: #{inspect(params)}"
      end
    end

    defp insert_columns([]), do: []

    defp insert_columns(header) do
      [" (", header |> Enum.map(&quote_identifier/1) |> Enum.intersperse(", "), ")"]
    end

    defp insert_rows(%Ecto.Query{} = query),
      do: ["(", Ecto.Adapters.QuackDB.Query.all(query), ")"]

    defp insert_rows(rows) when is_list(rows) do
      [
        "VALUES ",
        rows
        |> Enum.map(fn row ->
          ["(", row |> Enum.map(&insert_value/1) |> Enum.intersperse(", "), ")"]
        end)
        |> Enum.intersperse(", ")
      ]
    end

    defp insert_value(nil), do: "DEFAULT"

    defp insert_value({%Ecto.Query{} = query, _params_counter}),
      do: ["(", Ecto.Adapters.QuackDB.Query.all(query), ")"]

    defp insert_value({:placeholder, _placeholder_index}), do: "?"
    defp insert_value(_value), do: "?"

    defp on_conflict({:raise, _params, []}), do: []
    defp on_conflict({:nothing, _params, []}), do: " ON CONFLICT DO NOTHING"

    defp on_conflict({:nothing, _params, targets}) do
      [" ON CONFLICT ", conflict_target(targets), "DO NOTHING"]
    end

    defp on_conflict({_fields, _params, _targets}) do
      unsupported_iodata!(
        :schema_upserts,
        "Ecto upserts are not supported yet; use Repo.query/3 or QuackDB.insert_rows/4"
      )
    end

    defp conflict_target([]), do: []

    defp conflict_target(targets) when is_list(targets) do
      ["(", targets |> Enum.map(&quote_identifier/1) |> Enum.intersperse(", "), ") "]
    end

    defp conflict_target({:unsafe_fragment, fragment}), do: [fragment, " "]

    defp returning([], _placeholders), do: []

    defp returning(returning, []),
      do: [" RETURNING ", returning |> Enum.map(&quote_identifier/1) |> Enum.intersperse(", ")]

    defp returning(_returning, _placeholders) do
      unsupported_iodata!(:placeholders, ":placeholders with RETURNING are not supported yet")
    end

    defp quote_table(nil, table), do: quote_identifier(table)
    defp quote_table(prefix, table), do: [quote_identifier(prefix), ".", quote_identifier(table)]

    defp quote_identifier(value) do
      value = value |> to_string() |> String.replace("\"", "\"\"")
      ["\"", value, "\""]
    end

    defp normalize_result(%QuackDB.Result{} = result) do
      %{
        command: result.command,
        columns: result.columns,
        rows: result.rows,
        num_rows: result.num_rows,
        connection_id: result.connection_id,
        messages: result.messages,
        metadata: result.metadata
      }
    end

    defp unsupported_iodata!(feature, message) do
      if Application.get_env(:quackdb, :allow_unsupported_ecto_sql_generation, false) do
        "-- unsupported QuackDB Ecto feature: #{feature}"
      else
        unsupported!(feature, message)
      end
    end

    defp unsupported!(feature, message) do
      raise QuackDB.Error.new(:ecto_feature_not_supported, message,
              source: :client,
              metadata: %{feature: feature}
            )
    end
  end
end
