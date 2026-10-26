# Protocol decode microbenchmark: no server, just DataChunk/Vector decoding.
#
#     mix run bench/decode.exs
#
# Each line is the median time of several rounds for one decode. The scaling
# section decodes 2048 and 8192 values; linear decoders take about 4x as long.

alias QuackDB.Protocol.DataChunk
alias QuackDB.Protocol.LogicalType
alias QuackDB.Protocol.Variant
alias QuackDB.Protocol.Vector
alias QuackDB.Protocol.Writer

defmodule QuackDB.Bench.Decode do
  @rounds 7

  def measure(label, iterations, fun) do
    fun.()

    median =
      1..@rounds
      |> Enum.map(fn _round ->
        {microseconds, _result} = :timer.tc(fn -> for _ <- 1..iterations, do: fun.() end)
        microseconds / iterations
      end)
      |> Enum.sort()
      |> Enum.at(div(@rounds, 2))

    IO.puts(
      String.pad_trailing(label, 42) <>
        String.pad_leading(:erlang.float_to_binary(median, decimals: 1), 10) <> " µs"
    )
  end

  def chunk(columns, types) do
    {:ok, chunk} = DataChunk.from_columns(columns, columns: types)
    chunk |> DataChunk.encode() |> IO.iodata_to_binary()
  end

  def decode_chunk(binary) do
    {:ok, chunk, ""} = DataChunk.decode(binary)
    chunk
  end

  def dictionary(rows) do
    selection = for index <- 0..(rows - 1), into: <<>>, do: <<index::little-unsigned-32>>
    values = Vector.encode(LogicalType.new(:integer), Enum.to_list(1..rows), rows)

    IO.iodata_to_binary([
      Writer.field(90, Writer.uleb128(3)),
      Writer.field(91, Writer.blob(selection)),
      Writer.field(92, Writer.uleb128(rows)),
      values
    ])
  end

  def variant_array(count) do
    header = IO.iodata_to_binary([Writer.uleb128(count), Writer.uleb128(0)])
    integers = for value <- 1..count, into: <<>>, do: <<value::little-signed-32>>

    values =
      for index <- 0..(count - 1),
          do: %{"type_id" => 5, "byte_offset" => byte_size(header) + 4 * index}

    %{
      "keys" => [],
      "children" => for(index <- 1..count, do: %{"keys_index" => nil, "values_index" => index}),
      "values" => [%{"type_id" => 30, "byte_offset" => 0} | values],
      "data" => header <> integers
    }
  end
end

alias QuackDB.Bench.Decode

rows = 2048
range = Enum.to_list(1..rows)

columns = [
  {"integer", [n: range], [n: :integer]},
  {"integer, 1/3 NULL", [n: Enum.map(range, &if(rem(&1, 3) == 0, do: nil, else: &1))],
   [n: :integer]},
  {"bigint", [n: range], [n: :bigint]},
  {"double", [n: Enum.map(range, &(&1 * 1.5))], [n: :double]},
  {"decimal(18, 2)", [n: Enum.map(range, &Decimal.new(1, &1, -2))], [n: {:decimal, 18, 2}]},
  {"date", [n: Enum.map(range, &Date.add(~D[2026-01-01], &1))], [n: :date]},
  {"timestamp", [n: Enum.map(range, &NaiveDateTime.add(~N[2026-01-01 00:00:00], &1))],
   [n: :timestamp]},
  {"varchar", [n: Enum.map(range, &"value-#{&1}")], [n: :varchar]},
  {"integer[] (3 per row)", [n: Enum.map(range, &[&1, &1 + 1, &1 + 2])], [n: {:list, :integer}]},
  {"integer[4]", [n: Enum.map(range, &[&1, &1, &1, &1])], [n: {:array, :integer, 4}]},
  {"struct(a integer, b varchar)", [n: Enum.map(range, &%{a: &1, b: "x#{&1}"})],
   [n: {:struct, [a: :integer, b: :varchar]}]}
]

IO.puts("Decode one #{rows}-row chunk:")

for {label, values, types} <- columns do
  binary = Decode.chunk(values, types)
  Decode.measure("  " <> label, 100, fn -> Decode.decode_chunk(binary) end)
end

IO.puts("\nScaling:")

for count <- [2048, 8192] do
  binary = Decode.dictionary(count)

  Decode.measure("  dictionary, #{count} rows", 20, fn ->
    {:ok, _vector, ""} = Vector.decode(binary, LogicalType.new(:integer), count)
  end)
end

for count <- [2048, 8192] do
  binary = Decode.chunk([n: Enum.map(1..count, &[&1, &1, &1, &1])], n: {:array, :integer, 4})
  Decode.measure("  integer[4], #{count} rows", 20, fn -> Decode.decode_chunk(binary) end)
end

for count <- [2048, 8192] do
  row = Decode.variant_array(count)
  Decode.measure("  VARIANT array, #{count} elements", 20, fn -> Variant.decode_rows([row]) end)
end

chunk =
  Decode.decode_chunk(Decode.chunk(elem(Enum.at(columns, -1), 1), elem(Enum.at(columns, -1), 2)))

IO.puts("")
Decode.measure("DataChunk.rows/1, struct chunk", 100, fn -> DataChunk.rows(chunk) end)
