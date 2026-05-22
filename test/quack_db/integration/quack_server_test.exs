defmodule QuackDB.IntegrationRepo do
  use Ecto.Repo,
    otp_app: :quackdb,
    adapter: Ecto.Adapters.QuackDB
end

defmodule QuackDB.Integration.QuackServerTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  @moduletag :integration

  test "queries a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["n"], rows: [[1]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT 1 AS n")
  end

  test "decodes mixed scalar results from a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["ok", "name", "amount"]} = result} =
             QuackDB.query(
               connection,
               "SELECT true AS ok, 'duck' AS name, 12.5::DOUBLE AS amount"
             )

    assert result.rows == [[true, "duck", 12.5]]
  end

  test "decodes nulls, temporal values, and decimals from a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["n", "s", "d", "ts", "dec"]} = result} =
             QuackDB.query(
               connection,
               "SELECT NULL::INTEGER AS n, NULL::VARCHAR AS s, DATE '2024-01-02' AS d, TIMESTAMP '2024-01-02 03:04:05' AS ts, 12.34::DECIMAL(18,2) AS dec"
             )

    assert result.rows == [
             [nil, nil, ~D[2024-01-02], ~N[2024-01-02 03:04:05.000000], Decimal.new("12.34")]
           ]
  end

  test "fetches large result sets from a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{} = result} =
             QuackDB.query(connection, "SELECT i::INTEGER AS n FROM range(0, 50000) t(i)")

    assert result.metadata.needs_more_fetch == true
    assert result.num_rows == 50_000
    assert hd(result.rows) == [0]
    assert List.last(result.rows) == [49_999]
  end

  test "streams large result sets from a real Quack server" do
    connection = start_connection!()

    assert {:ok, rows} =
             DBConnection.transaction(connection, fn tx ->
               tx
               |> QuackDB.stream("SELECT i::INTEGER AS n FROM range(0, 50000) t(i)", [],
                 max_rows: 1000
               )
               |> Enum.flat_map(& &1.rows)
             end)

    assert length(rows) == 50_000
    assert hd(rows) == [0]
    assert List.last(rows) == [49_999]
  end

  test "decodes nested DuckDB types from a real Quack server" do
    connection = start_connection!()

    assert {:ok, %QuackDB.Result{columns: ["xs", "obj", "arr", "m", "nested"]} = result} =
             QuackDB.query(
               connection,
               "SELECT [1,2,3] AS xs, {'name': 'duck', 'count': 2} AS obj, array_value(1,2,3) AS arr, map(['a','b'], [1,2]) AS m, [{'a': 1}, {'a': 2}] AS nested"
             )

    assert result.rows == [
             [
               [1, 2, 3],
               %{"name" => "duck", "count" => 2},
               [1, 2, 3],
               %{"a" => 1, "b" => 2},
               [%{"a" => 1}, %{"a" => 2}]
             ]
           ]
  end

  test "normalizes command affected row counts from a real Quack server" do
    connection = start_connection!()
    table = "quackdb_command_#{System.unique_integer([:positive])}"

    assert {:ok, %QuackDB.Result{command: :create, columns: nil, rows: nil, num_rows: 0} = create} =
             QuackDB.query(connection, "CREATE TEMP TABLE #{table}(id INTEGER, name VARCHAR)")

    assert create.metadata[:duckdb_columns] == ["Count"]
    assert create.metadata[:duckdb_rows] == []

    assert {:ok, %QuackDB.Result{command: :insert, columns: nil, rows: nil, num_rows: 2} = insert} =
             QuackDB.query(connection, "INSERT INTO #{table} VALUES (1, 'duck'), (2, 'goose')")

    assert insert.metadata[:duckdb_rows] == [[2]]

    assert {:ok, %QuackDB.Result{command: :update, columns: nil, rows: nil, num_rows: 1} = update} =
             QuackDB.query(connection, "UPDATE #{table} SET name = 'mallard' WHERE id = 1")

    assert update.metadata[:duckdb_rows] == [[1]]

    assert {:ok, %QuackDB.Result{command: :delete, columns: nil, rows: nil, num_rows: 1} = delete} =
             QuackDB.query(connection, "DELETE FROM #{table} WHERE id = 2")

    assert delete.metadata[:duckdb_rows] == [[1]]

    assert {:ok, %QuackDB.Result{columns: ["name"], rows: [["mallard"]], num_rows: 1}} =
             QuackDB.query(connection, "SELECT name FROM #{table}")
  end

  test "transactions roll back through DBConnection" do
    connection = start_connection!()
    table = "qrollback_#{System.unique_integer([:positive])}"

    assert {:error, :rolled_back} =
             DBConnection.transaction(connection, fn tx ->
               QuackDB.query!(tx, "CREATE TEMP TABLE #{table}(v INTEGER)")
               QuackDB.query!(tx, "INSERT INTO #{table} VALUES (1)")
               DBConnection.rollback(tx, :rolled_back)
             end)

    assert {:error, %QuackDB.Error{message: message}} =
             QuackDB.query(connection, "SELECT count(*) FROM #{table}")

    assert message =~ "does not exist"
  end

  test "Ecto Repo.query/3 works against a real Quack server" do
    start_repo!()

    assert {:ok, %{columns: ["n"], rows: [[1]], num_rows: 1, command: :select}} =
             QuackDB.IntegrationRepo.query("SELECT 1 AS n")

    table = "quackdb_ecto_#{System.unique_integer([:positive])}"

    assert {:ok, %{command: :create, rows: nil, num_rows: 0}} =
             QuackDB.IntegrationRepo.query("CREATE TEMP TABLE #{table}(id INTEGER)")

    assert {:ok, %{command: :insert, rows: nil, num_rows: 2} = insert} =
             QuackDB.IntegrationRepo.query("INSERT INTO #{table} VALUES (1), (2)")

    assert insert.metadata[:duckdb_rows] == [[2]]
  end

  test "Ecto Repo.all/2 executes simple read-only queries against a real Quack server" do
    start_repo!()
    table = "quackdb_ecto_all_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER, name VARCHAR)")
    QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1, 'duck'), (2, 'goose')")

    query =
      from(event in table,
        where: event.id > 1,
        select: %{id: event.id, name: event.name}
      )

    assert [%{id: 2, name: "goose"}] = QuackDB.IntegrationRepo.all(query)
  end

  test "Ecto Repo.all/2 supports aggregates and common predicates against a real Quack server" do
    start_repo!()
    table = "quackdb_ecto_agg_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER, name VARCHAR)")

    QuackDB.IntegrationRepo.query!(
      "INSERT INTO #{table} VALUES (1, 'duck'), (2, 'goose'), (3, NULL)"
    )

    query =
      from(event in table,
        where: like(event.name, "d%") and not is_nil(event.name),
        select: %{count: count(event.id)}
      )

    assert [%{count: 1}] = QuackDB.IntegrationRepo.all(query)

    fragment_query =
      from(event in table,
        where: event.id == 1,
        select: %{upper_name: fragment("upper(?)", event.name)}
      )

    assert [%{upper_name: "DUCK"}] = QuackDB.IntegrationRepo.all(fragment_query)
  end

  test "Ecto transactions commit through Repo.transaction/1" do
    start_repo!()
    table = "quackdb_ecto_commit_#{System.unique_integer([:positive])}"

    assert {:ok, :committed} =
             QuackDB.IntegrationRepo.transaction(fn ->
               QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER)")
               QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1), (2)")
               :committed
             end)

    assert %{rows: [[3]]} = QuackDB.IntegrationRepo.query!("SELECT SUM(id) FROM #{table}")
  end

  test "Ecto Repo.rollback/1 rolls back transaction work" do
    start_repo!()
    table = "quackdb_ecto_rollback_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER)")

    assert {:error, :rolled_back} =
             QuackDB.IntegrationRepo.transaction(fn ->
               QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1)")
               QuackDB.IntegrationRepo.rollback(:rolled_back)
             end)

    assert %{rows: [[0]]} = QuackDB.IntegrationRepo.query!("SELECT COUNT(*) FROM #{table}")
  end

  test "Ecto transactions roll back after query errors" do
    start_repo!()
    table = "quackdb_ecto_error_#{System.unique_integer([:positive])}"

    QuackDB.IntegrationRepo.query!("CREATE TEMP TABLE #{table}(id INTEGER)")

    assert {:error, %QuackDB.Error{message: message}} =
             QuackDB.IntegrationRepo.transaction(fn ->
               QuackDB.IntegrationRepo.query!("INSERT INTO #{table} VALUES (1)")

               case QuackDB.IntegrationRepo.query("SELEC broken") do
                 {:error, error} -> QuackDB.IntegrationRepo.rollback(error)
                 {:ok, result} -> flunk("expected query to fail, got: #{inspect(result)}")
               end
             end)

    assert message =~ "syntax error"
    assert %{rows: [[0]]} = QuackDB.IntegrationRepo.query!("SELECT COUNT(*) FROM #{table}")
  end

  test "propagates server errors with query context" do
    connection = start_connection!()

    assert {:error, %QuackDB.Error{} = error} = QuackDB.query(connection, "SELEC broken")
    assert error.message =~ "syntax error"
    assert error.query == "SELEC broken"
    assert is_binary(error.connection_id)
  end

  defp start_connection! do
    uri = System.fetch_env!("QUACKDB_TEST_URI")
    token = System.get_env("QUACKDB_TEST_TOKEN", "")

    start_supervised!({QuackDB, uri: uri, token: token})
  end

  defp start_repo! do
    Application.put_env(:quackdb, QuackDB.IntegrationRepo,
      uri: System.fetch_env!("QUACKDB_TEST_URI"),
      token: System.get_env("QUACKDB_TEST_TOKEN", ""),
      pool_size: 1,
      log: false
    )

    start_supervised!(QuackDB.IntegrationRepo)
  end
end
