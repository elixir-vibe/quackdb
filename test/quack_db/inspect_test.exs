defmodule QuackDB.InspectTest do
  use ExUnit.Case, async: true

  alias QuackDB.Protocol.LogicalType

  test "inspects results with row summaries and previews" do
    result = %QuackDB.Result{
      command: :select,
      columns: ["n"],
      rows: [[1], [2], [3], [4]],
      connection_id: "1234567890abcdef",
      metadata: %{needs_more_fetch: true}
    }

    inspected = inspect(result)

    assert inspected =~ "#QuackDB.Result<"
    assert inspected =~ "command: :select"
    assert inspected =~ "rows: 4"
    assert inspected =~ "preview: [[1], [2], [3], :...]"
    assert inspected =~ "connection_id: \"1234567890ab…\""
    assert inspected =~ "needs_more_fetch?: true"
  end

  test "inspects queries compactly" do
    query = %QuackDB.Query{
      statement: String.duplicate("SELECT 1 ", 20),
      columns: ["n"],
      result_uuid: 42
    }

    inspected = inspect(query)

    assert inspected =~ "#QuackDB.Query<"
    assert inspected =~ "statement: \"SELECT 1"
    assert inspected =~ "…"
    assert inspected =~ "columns: [\"n\"]"
    assert inspected =~ "result_uuid: 42"
  end

  test "inspects errors with context" do
    error =
      QuackDB.Error.new(:server_error, "syntax error",
        query: "SELEC broken",
        connection_id: "abcdef123456"
      )

    inspected = inspect(error)

    assert inspected =~ "#QuackDB.Error<"
    assert inspected =~ "code: :server_error"
    assert inspected =~ "source: :client"
    assert inspected =~ "message: \"syntax error\""
    assert inspected =~ "query: \"SELEC broken\""
  end

  test "inspects logical types" do
    decimal = %LogicalType{name: :decimal, type_info: %{width: 18, scale: 2}}
    list = %LogicalType{name: :list, type_info: %{child_type: %LogicalType{name: :integer}}}

    struct = %LogicalType{
      name: :struct,
      type_info: %{
        children: [
          %{name: "name", type: %LogicalType{name: :varchar}},
          %{name: "count", type: %LogicalType{name: :integer}}
        ]
      }
    }

    assert inspect(decimal) == "#QuackDB.LogicalType<type: :decimal, width: 18, scale: 2>"
    assert inspect(list) == "#QuackDB.LogicalType<type: :list, child: :integer>"
    assert inspect(struct) =~ "#QuackDB.LogicalType<type: :struct"
    assert inspect(struct) =~ "{\"name\", :varchar}"
    assert inspect(struct) =~ "{\"count\", :integer}"
  end
end
