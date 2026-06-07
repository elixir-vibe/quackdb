if Code.ensure_loaded?(Ecto.Type) do
  defmodule QuackDB.Ecto.Type do
    @moduledoc false

    @type column_usage :: :migration | :append | :schema

    @spec column_type!(Ecto.Type.t(), column_usage()) :: QuackDB.Type.spec()
    def column_type!(:map, :migration), do: :json
    def column_type!(:map, :append), do: :varchar
    def column_type!(:map, :schema), do: raise(ArgumentError, inspect(:map))

    def column_type!(type, usage) when usage in [:migration, :append, :schema],
      do: type |> normalize_type() |> base_type!()

    defp normalize_type({:parameterized, {module, params}}),
      do: Ecto.Type.type({:parameterized, {module, params}})

    defp normalize_type(type), do: type

    defp base_type!(:id), do: :bigint
    defp base_type!(:bigserial), do: :bigint
    defp base_type!(:serial), do: :integer
    defp base_type!(:binary_id), do: :uuid
    defp base_type!(:integer), do: :integer
    defp base_type!(:bigint), do: :bigint
    defp base_type!(:float), do: :double
    defp base_type!(:boolean), do: :boolean
    defp base_type!(:string), do: :varchar
    defp base_type!(:text), do: :varchar
    defp base_type!(:binary), do: :blob
    defp base_type!(:decimal), do: :decimal
    defp base_type!(:date), do: :date
    defp base_type!(type) when type in [:time, :time_usec], do: :time
    defp base_type!(type) when type in [:naive_datetime, :naive_datetime_usec], do: :timestamp
    defp base_type!(type) when type in [:utc_datetime, :utc_datetime_usec], do: :timestamp_tz
    defp base_type!({:array, type}), do: {:list, base_type!(type)}

    defp base_type!(type) do
      raise ArgumentError, inspect(type)
    end
  end
end
