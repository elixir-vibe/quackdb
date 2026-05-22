if Code.ensure_loaded?(Ecto.Adapters.SQL.Connection) do
  defmodule Ecto.Adapters.QuackDB.Connection do
    @moduledoc """
    Ecto SQL connection callbacks backed by `QuackDB.DBConnection`.

    This module currently implements the raw query path used by
    `Ecto.Adapters.SQL.query/4` and `Repo.query/3`. Higher-level Ecto query
    generation callbacks raise explicit unsupported-feature errors until the
    adapter grows beyond raw SQL execution.
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
    def all(_query),
      do:
        unsupported_iodata!(
          :schema_queries,
          "Ecto schema queries are not supported yet; use Repo.query/3"
        )

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
    def insert(_prefix, _table, _header, _rows, _on_conflict, _returning, _placeholders) do
      unsupported_iodata!(:schema_inserts, "Ecto inserts are not supported yet; use Repo.query/3")
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
