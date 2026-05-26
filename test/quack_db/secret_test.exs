defmodule QuackDB.SecretTest do
  use ExUnit.Case, async: true

  test "builds credential-chain S3 secrets" do
    assert QuackDB.Secret.s3(provider: :credential_chain)
           |> IO.iodata_to_binary() ==
             "CREATE OR REPLACE SECRET (TYPE s3, PROVIDER credential_chain);"
  end

  test "builds named HTTP secrets with headers" do
    assert QuackDB.Secret.http(
             name: :http_auth,
             bearer_token: "secret",
             extra_http_headers: %{"Authorization" => "Bearer token"}
           )
           |> IO.iodata_to_binary() ==
             "CREATE OR REPLACE SECRET http_auth (TYPE http, BEARER_TOKEN 'secret', EXTRA_HTTP_HEADERS MAP {'Authorization': 'Bearer token'});"
  end

  test "builds cloud provider secrets" do
    assert QuackDB.Secret.r2(account_id: "abc", key_id: "key", secret: "secret")
           |> IO.iodata_to_binary() ==
             "CREATE OR REPLACE SECRET (TYPE r2, ACCOUNT_ID 'abc', KEY_ID 'key', SECRET 'secret');"

    assert QuackDB.Secret.gcs(key_id: "key", secret: "secret")
           |> IO.iodata_to_binary() ==
             "CREATE OR REPLACE SECRET (TYPE gcs, KEY_ID 'key', SECRET 'secret');"

    assert QuackDB.Secret.azure(provider: :credential_chain, account_name: "storage")
           |> IO.iodata_to_binary() ==
             "CREATE OR REPLACE SECRET (TYPE azure, PROVIDER credential_chain, ACCOUNT_NAME 'storage');"
  end

  test "builds temporary named secrets without replace" do
    assert QuackDB.Secret.hugging_face(
             name: :hf_token,
             replace: false,
             temporary: true,
             token: "hf_123"
           )
           |> IO.iodata_to_binary() ==
             "CREATE TEMPORARY SECRET hf_token (TYPE huggingface, TOKEN 'hf_123');"
  end

  test "rejects invalid identifiers" do
    assert_raise ArgumentError, ~r/invalid DuckDB secret secret identifier/, fn ->
      QuackDB.Secret.s3(name: "bad-name")
    end

    assert_raise ArgumentError, ~r/invalid DuckDB secret option identifier/, fn ->
      QuackDB.Secret.s3([{:"bad-name", "value"}])
    end
  end
end
