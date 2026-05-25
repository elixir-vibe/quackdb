defmodule QuackDB.Inspect do
  @moduledoc """
  Shared helpers for compact `Inspect` protocol implementations.

  The helpers keep IEx output useful for manual protocol debugging by truncating
  large strings, shortening connection ids, and summarizing potentially large
  row sets.
  """

  import Inspect.Algebra

  @preview_limit 3
  @string_limit 80
  @id_limit 12

  def container(name, fields, opts) do
    filtered_fields = Enum.reject(fields, fn {_key, value} -> value in [nil, [], %{}] end)

    concat([
      string("#"),
      string(name),
      string("<"),
      container_doc(filtered_fields, opts),
      string(">"),
      empty()
    ])
  end

  def rows_summary(nil), do: nil
  def rows_summary(rows), do: length(rows)

  def rows_preview(nil), do: nil
  def rows_preview([]), do: []

  def rows_preview(rows) do
    {preview, rest} = Enum.split(rows, @preview_limit)

    case rest do
      [] -> preview
      [_ | _] -> preview |> Enum.reverse() |> then(&[:... | &1]) |> Enum.reverse()
    end
  end

  def truncate(value, limit \\ @string_limit)
  def truncate(nil, _limit), do: nil

  def truncate(value, limit) do
    value = IO.iodata_to_binary(value)

    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "…"
    else
      value
    end
  end

  def short_id(nil), do: nil
  def short_id(value), do: truncate(value, @id_limit)

  defp container_doc([], _opts), do: empty()

  defp container_doc(fields, opts) do
    fields
    |> Enum.map(fn {key, value} -> field_doc(key, value, opts) end)
    |> Enum.intersperse(concat(string(","), break(" ")))
    |> concat()
  end

  defp field_doc(key, value, opts) do
    concat([string(Atom.to_string(key)), string(": "), to_doc(value, opts)])
  end
end
