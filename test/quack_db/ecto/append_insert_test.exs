defmodule QuackDB.Ecto.AppendInsertTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.QuackDB.AppendInsert

  test "converts Ecto insert rows to column vectors in header order" do
    assert AppendInsert.__append_columns__(
             [:id, :name],
             [[id: 1, name: "duck"], [id: 2, name: "goose"]],
             columns: [id: :integer, name: :varchar]
           ) == [id: [1, 2], name: ["duck", "goose"]]
  end

  test "normalizes map values for varchar columns" do
    columns =
      AppendInsert.__append_columns__(
        [:payload],
        [[payload: %{name: "duck"}], [payload: %{name: "goose"}]],
        columns: [payload: :varchar]
      )

    assert [{:payload, [duck, goose]}] = columns
    assert {:ok, %{"name" => "duck"}} = JSON.decode(duck)
    assert {:ok, %{"name" => "goose"}} = JSON.decode(goose)
  end

  test "treats json Ecto types as varchar append columns" do
    columns =
      AppendInsert.__append_columns__(
        [:payload],
        [[payload: %{name: "duck"}]],
        columns: [payload: {:json, :map}]
      )

    assert [{:payload, [payload]}] = columns
    assert {:ok, %{"name" => "duck"}} = JSON.decode(payload)
  end
end
