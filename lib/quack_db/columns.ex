defmodule QuackDB.Columns do
  @moduledoc """
  Column-oriented query result.

  This struct preserves column order and result metadata while exposing vectors in
  a map keyed by disambiguated column names. It is intended for analytical
  workflows and as a stable bridge toward future Arrow/columnar integrations.
  """

  @type t :: %__MODULE__{
          names: [String.t()],
          original_names: [String.t()],
          columns: %{String.t() => [term()]},
          num_rows: non_neg_integer(),
          command: QuackDB.Result.command() | nil,
          connection_id: String.t() | nil,
          messages: [map()] | nil,
          metadata: map()
        }

  defstruct names: [],
            original_names: [],
            columns: %{},
            num_rows: 0,
            command: nil,
            connection_id: nil,
            messages: nil,
            metadata: %{}

  @doc "Returns a column vector by disambiguated name."
  @spec fetch(t(), String.t()) :: {:ok, [term()]} | :error
  def fetch(%__MODULE__{columns: columns}, name), do: Map.fetch(columns, name)

  @doc "Returns a column vector by disambiguated name, or `default` when absent."
  @spec get(t(), String.t(), term()) :: [term()] | term()
  def get(%__MODULE__{columns: columns}, name, default \\ nil),
    do: Map.get(columns, name, default)

  @doc "Converts column vectors back to row lists."
  @spec to_rows(t()) :: [[term()]]
  def to_rows(%__MODULE__{names: names, columns: columns, num_rows: num_rows}) do
    for index <- 0..(num_rows - 1)//1 do
      Enum.map(names, fn name -> columns |> Map.fetch!(name) |> Enum.at(index) end)
    end
  end

  @doc "Converts column vectors to row maps keyed by disambiguated column names."
  @spec to_maps(t()) :: [%{String.t() => term()}]
  def to_maps(%__MODULE__{names: names, columns: columns, num_rows: num_rows}) do
    for index <- 0..(num_rows - 1)//1 do
      Map.new(names, fn name -> {name, columns |> Map.fetch!(name) |> Enum.at(index)} end)
    end
  end

  @doc "Raises because column result structs are read-only."
  def get_and_update(_columns, _key, _function),
    do: raise(ArgumentError, "QuackDB.Columns is read-only")

  @doc "Raises because column result structs are read-only."
  def pop(_columns, _key), do: raise(ArgumentError, "QuackDB.Columns is read-only")
end

defimpl Enumerable, for: QuackDB.Columns do
  def count(%QuackDB.Columns{names: names}), do: {:ok, length(names)}

  def member?(%QuackDB.Columns{columns: columns}, {name, values}),
    do: {:ok, Map.get(columns, name) == values}

  def member?(_columns, _other), do: {:ok, false}
  def slice(_columns), do: {:error, __MODULE__}

  def reduce(%QuackDB.Columns{names: names, columns: columns}, acc, fun) do
    names
    |> Enum.map(fn name -> {name, Map.fetch!(columns, name)} end)
    |> Enumerable.List.reduce(acc, fun)
  end
end
