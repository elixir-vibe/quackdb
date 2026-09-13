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

  defmodule CreateTypedCheckedTable do
    use Ecto.Migration
    import QuackDB.DDL, only: [create_table: 3, drop_table: 1, check: 1]

    def change do
      maximum = 100

      execute(
        fn ->
          repo().query!(
            create_table(
              :typed_checked_events,
              [{:score, :integer, null: false}, {:optional_score, :integer}, {:label, :varchar}],
              [
                check(score >= 0 and score < ^maximum),
                check(optional_score >= 0),
                check(label != "duck's")
              ]
            )
          )
        end,
        fn -> repo().query!(drop_table(:typed_checked_events)) end
      )
    end
  end

  test "single and list CHECK arguments enforce the same bounds" do
    import QuackDB.DDL, only: [create_table: 3, check: 1]
    start_repo!()
    maximum = 3

    for {table, constraints, count} <- [
          {"single_check", check(score >= 0 and score < ^maximum), 1},
          {"separate_checks", [check(score >= 0), check(score < ^maximum)], 2}
        ] do
      Repo.query!(create_table(table, [{:score, :integer, null: false}], constraints))
      assert {2, nil} = Repo.insert_all(table, [%{score: 0}, %{score: 2}])

      for score <- [-1, 3] do
        assert_raise QuackDB.Error, ~r/CHECK constraint failed/, fn ->
          Repo.insert_all(table, [%{score: score}])
        end
      end

      assert %{rows: [[^count]]} =
               Repo.query!(
                 "SELECT count(*) FROM duckdb_constraints() WHERE table_name = ? AND constraint_type = 'CHECK'",
                 [table]
               )
    end
  end

  test "typed inline CHECKs are enforced through reversible Ecto migrations" do
    start_repo!()
    version = 20_260_913_000_003
    assert :ok = Ecto.Migrator.up(Repo, version, CreateTypedCheckedTable, log: false)

    assert {1, nil} =
             Repo.insert_all("typed_checked_events", [
               %{score: 0, optional_score: nil, label: "duck"}
             ])

    assert {1, nil} =
             Repo.insert_all("typed_checked_events", [
               %{score: 99, optional_score: 5, label: "goose"}
             ])

    for row <- [
          %{score: -1},
          %{score: 100},
          %{score: 1, optional_score: -1},
          %{score: 1, label: "duck's"}
        ] do
      error = assert_raise QuackDB.Error, fn -> Repo.insert_all("typed_checked_events", [row]) end
      assert error.message =~ "CHECK constraint failed"
    end

    assert_raise QuackDB.Error, ~r/NOT NULL constraint failed/, fn ->
      Repo.insert_all("typed_checked_events", [%{score: nil}])
    end

    assert %{rows: [[0, nil, "duck"], [99, 5, "goose"]]} =
             Repo.query!(
               "SELECT score, optional_score, label FROM typed_checked_events ORDER BY score"
             )

    assert :ok = Ecto.Migrator.down(Repo, version, CreateTypedCheckedTable, log: false)

    assert %{rows: []} =
             Repo.query!(
               "SELECT * FROM duckdb_tables() WHERE table_name = 'typed_checked_events'"
             )
  end

  defmodule AddReferencedRevision do
    use Ecto.Migration

    def change do
      alter table(:referenced_projects) do
        add(:schema_revision, :integer, null: false, default: 1)
      end
    end
  end

  test "a referenced-table NOT NULL failure rolls back the whole Ecto migration" do
    start_repo!()
    Repo.query!("CREATE TABLE referenced_projects (id INTEGER PRIMARY KEY)")

    Repo.query!(
      "CREATE TABLE project_references (project_id INTEGER REFERENCES referenced_projects(id))"
    )

    Repo.insert_all("referenced_projects", [%{id: 1}])
    Repo.insert_all("project_references", [%{project_id: 1}])
    version = 20_260_913_000_002

    error =
      assert_raise QuackDB.Error, fn ->
        Ecto.Migrator.up(Repo, version, AddReferencedRevision, log: false)
      end

    assert error.code == :server_error
    assert error.source == :server
    assert error.message =~ "Cannot alter entry"
    assert error.message =~ "entries that depend on it"

    assert %{rows: []} =
             Repo.query!("""
             SELECT column_name FROM information_schema.columns
             WHERE table_name = 'referenced_projects' AND column_name = 'schema_revision'
             """)

    assert %{rows: []} =
             Repo.query!("SELECT version FROM schema_migrations WHERE version = ?", [version])

    assert %{rows: [[1]]} = Repo.query!("SELECT * FROM referenced_projects")
    assert %{rows: [[1]]} = Repo.query!("SELECT * FROM project_references")

    assert {:error, %QuackDB.Error{message: message}} =
             Repo.query("INSERT INTO project_references VALUES (999)")

    assert message =~ "foreign key constraint"
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
