defmodule QuackDB.Protocol.QuackTsConformanceTest do
  use ExUnit.Case, async: true

  import QuackDB.ProtocolAssertions

  alias QuackDB.ProtocolCrossFixtures

  @fixture_dir Path.expand("../../fixtures/quack_ts", __DIR__)

  for fixture <- ProtocolCrossFixtures.all() do
    @fixture_name fixture.name
    @fixture_file fixture.file
    @fixture_encoder fixture.encoder

    test "#{@fixture_name} encoding matches quack-ts" do
      actual = apply(ProtocolCrossFixtures, @fixture_encoder, [])

      assert_same_binary(actual, read_fixture!(@fixture_file))
    end
  end

  defp read_fixture!(file) do
    @fixture_dir
    |> Path.join(file)
    |> File.read!()
  end
end
