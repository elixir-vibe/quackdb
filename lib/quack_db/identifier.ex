defmodule QuackDB.Identifier do
  @moduledoc false

  @spec valid?(atom() | String.t()) :: boolean()
  def valid?(value) when is_atom(value), do: value |> Atom.to_string() |> valid?()

  def valid?(<<?_, rest::binary>>), do: valid_rest?(rest)

  def valid?(<<first, rest::binary>>) when first in ?A..?Z or first in ?a..?z do
    valid_rest?(rest)
  end

  def valid?(_value), do: false

  defp valid_rest?(<<>>), do: true

  defp valid_rest?(<<?_, rest::binary>>), do: valid_rest?(rest)

  defp valid_rest?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 do
    valid_rest?(rest)
  end

  defp valid_rest?(_value), do: false
end
