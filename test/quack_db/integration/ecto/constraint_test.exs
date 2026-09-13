defmodule QuackDB.Integration.Ecto.ConstraintTest do
  use ExUnit.Case, async: false

  import QuackDB.QuackServerCase

  alias Ecto.Adapters.QuackDB.Connection
  alias Ecto.Migration.Constraint
  alias QuackDB.IntegrationRepo, as: Repo

  @moduletag :integration

  defmodule CreateCheckedTable do
    use Ecto.Migration

    def change do
      execute(
        """
        CREATE TABLE checked_events (
          id INTEGER PRIMARY KEY,
          score INTEGER DEFAULT 0,
          CONSTRAINT positive_score CHECK (score >= 0),
          CONSTRAINT max_score CHECK (score < 100)
        )
        """,
        "DROP TABLE checked_events"
      )
    end
  end

  test "inline CHECK constraints work through reversible Ecto migrations" do
    start_repo!()
    version = 20_260_913_000_001
    assert :ok = Ecto.Migrator.up(Repo, version, CreateCheckedTable, log: false)
    Repo.query!("INSERT INTO checked_events VALUES (1, 5)")

    assert {:error, %QuackDB.Error{message: message}} =
             Repo.query("INSERT INTO checked_events VALUES (2, -1)")

    assert message =~ "CHECK constraint failed"
    assert %{rows: [[1, 5]]} = Repo.query!("SELECT * FROM checked_events")
    assert :ok = Ecto.Migrator.down(Repo, version, CreateCheckedTable, log: false)

    assert %{rows: []} =
             Repo.query!("SELECT * FROM duckdb_tables() WHERE table_name = 'checked_events'")
  end

  test "DuckDB catalog loses supplied CHECK names and can generate duplicate names" do
    start_repo!()

    Repo.query!("""
    CREATE TEMP TABLE checked_events (
      score INTEGER,
      CONSTRAINT positive_score CHECK (score >= 0),
      CONSTRAINT max_score CHECK (score < 100)
    )
    """)

    assert %{rows: [["checked_events_score_check"], ["checked_events_score_check"]]} =
             Repo.query!("""
             SELECT constraint_name FROM duckdb_constraints()
             WHERE table_name = 'checked_events' AND constraint_type = 'CHECK'
             ORDER BY constraint_index
             """)

    assert %{rows: [[sql]]} =
             Repo.query!("SELECT sql FROM duckdb_tables() WHERE table_name = 'checked_events'")

    refute sql =~ "positive_score"
    refute sql =~ "max_score"
  end

  test "a failed write prevents catalog lookup in the same transaction" do
    start_repo!()
    Repo.query!("CREATE TEMP TABLE unique_events (id INTEGER PRIMARY KEY)")
    Repo.query!("INSERT INTO unique_events VALUES (1)")

    assert {:error, :verified} =
             Repo.transaction(fn ->
               assert {:error, %QuackDB.Error{} = error} =
                        Repo.query("INSERT INTO unique_events VALUES (1)")

               assert error.message =~ "violates primary key constraint"
               assert Connection.to_constraints(error, []) == []

               assert {:error, %QuackDB.Error{message: message}} =
                        Repo.query("SELECT * FROM duckdb_constraints()")

               assert message =~ "transaction is aborted"
               Repo.rollback(:verified)
             end)
  end

  test "constraint alterations fail explicitly in the adapter and are unsupported by DuckDB" do
    start_repo!()
    Repo.query!("CREATE TEMP TABLE checked_events (score INTEGER CHECK (score >= 0))")
    constraint = %Constraint{table: "checked_events", name: "positive_score", check: "score >= 0"}

    for {command, sql} <- [
          {{:create, constraint},
           "ALTER TABLE checked_events ADD CONSTRAINT positive_score CHECK (score >= 0)"},
          {{:drop, constraint, :restrict},
           "ALTER TABLE checked_events DROP CONSTRAINT positive_score"}
        ] do
      error = assert_raise QuackDB.Error, fn -> Connection.execute_ddl(command) end
      assert error.code == :ecto_feature_not_supported
      assert error.metadata.feature == :migration_constraint
      assert {:error, %QuackDB.Error{message: message}} = Repo.query(sql)
      assert message =~ "No support for that ALTER TABLE option yet"
    end
  end
end
