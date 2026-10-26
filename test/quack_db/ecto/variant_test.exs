defmodule QuackDB.Ecto.VariantTest do
  use ExUnit.Case, async: true

  alias Ecto.Adapters.QuackDB.Connection

  test "builds VARIANT inspection and extraction expressions" do
    defmodule VariantQuery do
      import Ecto.Query
      import QuackDB.Ecto.Variant

      def query do
        from(event in "events",
          where: variant_type(event.payload) == "OBJECT",
          where: variant_contains(event.payload, ^"duck"),
          select: %{
            kind: variant_extract_string(event.payload, "kind"),
            tag: variant_extract(event.payload, [:tags, 1]),
            field: variant_extract(event.payload, ^"dynamic"),
            nested_type: variant_type(event.payload, :tags),
            typeof: variant_typeof(event.payload),
            keys: variant_keys(event.payload),
            nested_keys: variant_keys(event.payload, "meta"),
            length: variant_array_length(event.payload, :tags)
          }
        )
      end
    end

    assert VariantQuery.query() |> Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT variant_extract_string(q0."payload", 'kind') AS "kind", variant_extract(variant_extract(q0."payload", 'tags'), CAST(1 AS UINTEGER)) AS "tag", variant_extract(q0."payload", ?) AS "field", variant_type(q0."payload", 'tags') AS "nested_type", variant_typeof(q0."payload") AS "typeof", variant_keys(q0."payload") AS "keys", variant_keys(q0."payload", 'meta') AS "nested_keys", variant_array_length(q0."payload", 'tags') AS "length" FROM "events" AS q0 WHERE (variant_type(q0."payload") = 'OBJECT') AND variant_contains(q0."payload", CAST(? AS VARIANT))]
  end

  test "rejects zero-based VARIANT array indexes at compile time" do
    assert_raise ArgumentError, ~r/count from 1/, fn ->
      Code.eval_string("""
      import Ecto.Query
      import QuackDB.Ecto.Variant
      from(event in "events", select: variant_extract(event.payload, [:tags, 0]))
      """)
    end
  end

  test "use QuackDB.Ecto imports the VARIANT helpers" do
    defmodule BroadVariantQuery do
      use QuackDB.Ecto

      def query, do: from(event in "events", select: variant_keys(event.payload))
    end

    assert BroadVariantQuery.query() |> Connection.all() |> IO.iodata_to_binary() ==
             ~S[SELECT variant_keys(q0."payload") FROM "events" AS q0]
  end
end
