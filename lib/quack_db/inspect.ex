defmodule QuackDB.Inspect do
  @moduledoc false

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
    preview = Enum.take(rows, @preview_limit)

    if length(rows) > @preview_limit do
      preview ++ [:...]
    else
      preview
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
