defmodule QuackDB.Extension do
  @moduledoc """
  SQL builders for DuckDB extension management.

  These helpers build `INSTALL` and `LOAD` statements while validating extension
  names as SQL identifiers. They return iodata so they can be passed directly to
  `QuackDB.query/4`, `QuackDB.query!/4`, or `Repo.query/3`.

      alias QuackDB.Extension

      QuackDB.query!(conn, Extension.install(:httpfs))
      QuackDB.query!(conn, Extension.load(:httpfs))

  `QuackDB.SQL.install/1` and `QuackDB.SQL.load/1` remain available as the
  lower-level generic SQL helpers.
  """

  @doc "Builds an `INSTALL extension;` statement."
  @spec install(atom() | String.t()) :: iodata()
  def install(extension), do: QuackDB.SQL.install(extension)

  @doc "Builds a `LOAD extension;` statement."
  @spec load(atom() | String.t()) :: iodata()
  def load(extension), do: QuackDB.SQL.load(extension)
end
