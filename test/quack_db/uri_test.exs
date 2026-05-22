defmodule QuackDB.URITest do
  use ExUnit.Case, async: true

  alias QuackDB.URI

  test "normalizes bare hosts" do
    assert {:ok, uri} = URI.normalize("localhost:9494")
    assert uri.scheme == "http"
    assert uri.host == "localhost"
    assert uri.port == 9494
    assert uri.path == "/quack"
  end

  test "normalizes quack URIs to HTTP endpoint URIs" do
    assert {:ok, uri} = URI.normalize("quack://example.com")
    assert to_string(uri) == "http://example.com/quack"
  end

  test "keeps explicit HTTP paths" do
    assert {:ok, uri} = URI.normalize("https://example.com/custom")
    assert to_string(uri) == "https://example.com/custom"
  end

  test "rejects unsupported schemes" do
    assert {:error, %QuackDB.Error{code: :invalid_uri}} = URI.normalize("ftp://example.com")
  end
end
