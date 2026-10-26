defmodule QuackDB.DuckLakeTest do
  use ExUnit.Case, async: true

  alias QuackDB.DuckLake

  defmodule Order do
    use Ecto.Schema

    @schema_prefix "lake"
    schema("orders", do: field(:status, :string))
  end

  defmodule Invoice do
    use Ecto.Schema

    @schema_prefix "lake.billing"
    schema("invoices", do: field(:total, :integer))
  end

  test "snapshot table functions are Ecto and SQL sources" do
    assert DuckLake.snapshots(:lake) == "ducklake_snapshots('lake')"
    assert DuckLake.current_snapshot("lake") == "ducklake_current_snapshot('lake')"
    assert QuackDB.Source.source?(DuckLake.snapshots(:lake))
  end

  test "changes name the table and the snapshots between" do
    assert DuckLake.changes(:lake, :orders, from: 2, to: 5) ==
             "ducklake_table_changes('lake', 'main', 'orders', 2, 5)"

    assert DuckLake.insertions(:lake, {:sales, "orders"}, from: 2, to: ~U[2026-10-20 14:03:11Z]) ==
             "ducklake_table_insertions('lake', 'sales', 'orders', 2, TIMESTAMPTZ '2026-10-20T14:03:11Z')"

    assert DuckLake.deletions(:lake, Order, from: 1, to: 2) ==
             "ducklake_table_deletions('lake', 'main', 'orders', 1, 2)"

    assert DuckLake.changes(:lake, Invoice, from: 1, to: 2) ==
             "ducklake_table_changes('lake', 'billing', 'invoices', 1, 2)"

    assert_raise ArgumentError, ~r/expected :from and :to/, fn ->
      DuckLake.changes(:lake, :orders, from: -1, to: 2)
    end
  end

  test "commit messages and snapshot expiry build CALL statements" do
    assert IO.iodata_to_binary(DuckLake.set_commit_message(:lake, "checkout")) ==
             "CALL ducklake_set_commit_message('lake', NULL, 'checkout')"

    assert IO.iodata_to_binary(
             DuckLake.set_commit_message(:lake, "it's paid",
               author: "replay",
               extra_info: %{visit: 42}
             )
           ) ==
             ~s[CALL ducklake_set_commit_message('lake', 'replay', 'it''s paid', extra_info => '{"visit":42}')]

    assert IO.iodata_to_binary(
             DuckLake.expire_snapshots(:lake, older_than: ~U[2026-10-01 00:00:00Z])
           ) ==
             "CALL ducklake_expire_snapshots('lake', older_than => TIMESTAMPTZ '2026-10-01T00:00:00Z', dry_run => FALSE)"

    assert IO.iodata_to_binary(DuckLake.expire_snapshots(:lake, versions: [1, 2], dry_run: true)) ==
             "CALL ducklake_expire_snapshots('lake', versions => [1, 2], dry_run => TRUE)"

    assert_raise ArgumentError, ~r/expected :older_than/, fn ->
      DuckLake.expire_snapshots(:lake, [])
    end
  end
end
