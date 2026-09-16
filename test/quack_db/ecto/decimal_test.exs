defmodule QuackDB.Ecto.DecimalTest do
  use ExUnit.Case, async: true
  alias QuackDB.Ecto.Decimal, as: DuckDecimal

  test "validates precision and scale" do
    for {precision, scale} <- [{0, 0}, {39, 0}, {18, -1}, {18, 19}, {18.0, 2}, {18, "2"}] do
      assert_raise ArgumentError, fn ->
        Ecto.ParameterizedType.init(DuckDecimal, precision: precision, scale: scale)
      end
    end

    for {precision, scale} <- [{1, 0}, {38, 38}, {18, 4}] do
      assert {:parameterized, {DuckDecimal, %{precision: ^precision, scale: ^scale}}} =
               Ecto.ParameterizedType.init(DuckDecimal, precision: precision, scale: scale)
    end
  end

  test "preserves Ecto decimal casting, loading and dumping" do
    type = Ecto.ParameterizedType.init(DuckDecimal, precision: 18, scale: 4)
    value = Decimal.new("9.5001")
    assert Ecto.Type.type(type) == :decimal
    assert Ecto.Type.cast(type, "9.5001") == {:ok, value}
    assert Ecto.Type.dump(type, value) == {:ok, value}
    assert Ecto.Type.load(type, value) == {:ok, value}
    assert Ecto.Type.cast(type, "invalid") == :error
    assert Ecto.Type.cast(type, nil) == {:ok, nil}
  end
end
