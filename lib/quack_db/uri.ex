defmodule QuackDB.URI do
  @moduledoc """
  URI normalization for Quack HTTP endpoints.

  Accepts bare hosts, `quack://`, `http://`, and `https://` values, then returns
  a normalized `%URI{}` with the `/quack` path default expected by DuckDB Quack
  servers.
  """

  alias QuackDB.Error

  @spec normalize(String.t()) :: {:ok, URI.t()} | {:error, Error.t()}
  def normalize(value) when is_binary(value) do
    value
    |> ensure_scheme()
    |> URI.parse()
    |> normalize_parsed()
  end

  defp ensure_scheme(value) do
    if String.contains?(value, "://") do
      value
    else
      "http://" <> value
    end
  end

  defp normalize_parsed(%URI{scheme: "quack"} = uri) do
    normalize_http(%{uri | scheme: "http"})
  end

  defp normalize_parsed(%URI{scheme: scheme} = uri) when scheme in ["http", "https"] do
    normalize_http(uri)
  end

  defp normalize_parsed(%URI{scheme: scheme}) do
    error(:invalid_uri, "unsupported Quack URI scheme #{inspect(scheme)}")
  end

  defp normalize_http(%URI{host: host} = uri) when is_binary(host) and host != "" do
    {:ok, %{uri | path: normalize_path(uri.path)}}
  end

  defp normalize_http(_uri) do
    error(:invalid_uri, "Quack URI must include a host")
  end

  defp normalize_path(nil), do: "/quack"
  defp normalize_path(""), do: "/quack"
  defp normalize_path("/"), do: "/quack"
  defp normalize_path(path), do: path

  defp error(code, message) do
    {:error, Error.new(code, message, source: :client)}
  end
end
