defmodule QuackDB.ProfileTest do
  use ExUnit.Case, async: true

  alias QuackDB.Profile
  alias QuackDB.Profile.Operator

  test "JSONCodec builds recursive operators and preserves open-ended string keys" do
    extra = %{
      "operator_name" => "not a node",
      "children" => [%{"cpu_time" => 42}],
      "unknown_metric" => true
    }

    assert {:ok, profile} =
             Profile.from_map(%{
               "latency" => 0.01,
               "extra_info" => extra,
               "optimizers" => %{"join_order" => 0.002},
               "unknown_top_level" => 99,
               "children" => [
                 %{
                   "operator_name" => "ROOT",
                   "children" => [
                     %{
                       "operator_name" => "LEAF",
                       "extra_info" => extra,
                       "system_peak_buffer_memory" => 123
                     }
                   ]
                 }
               ]
             })

    assert profile.extra_info == extra
    assert profile.optimizers == %{"join_order" => 0.002}
    assert [%Operator{operator_name: "ROOT", children: [%Operator{} = leaf]}] = profile.children
    assert leaf.operator_name == "LEAF"
    assert leaf.extra_info == extra
    assert leaf.system_peak_buffer_memory == 123
    assert leaf.children == []
    assert profile.rows_returned == nil
  end

  test "profile schemas export recursive operators as local references" do
    assert Operator.schema()["properties"]["children"]["items"] == %{"$ref" => "#"}

    schema = Profile.schema()

    assert schema["properties"]["children"]["items"]["properties"]["children"]["items"] ==
             %{"$ref" => "#/properties/children/items"}

    assert JSON.decode!(JSON.encode!(schema)) == schema
    assert Profile.json_schema() == schema
  end

  test "malformed known profile fields fail instead of leaking undecoded values" do
    for input <- [
          %{"latency" => "fast"},
          %{"children" => "invalid"},
          %{"children" => [%{"operator_timing" => "fast"}]}
        ] do
      assert {:error, %JSONCodec.Error{}} = Profile.from_map(input)
    end
  end

  test "flattens and reports slow operators" do
    profile = %Profile{
      latency: 0.004,
      cpu_time: 0.002,
      rows_returned: 5,
      cumulative_rows_scanned: 1_000,
      system_peak_buffer_memory: 1_736_704,
      children: [
        %Operator{
          operator_name: "TOP_N",
          operator_type: "TOP_N",
          operator_timing: 0.0005,
          operator_cardinality: 5,
          operator_rows_scanned: 0,
          children: [
            %Operator{
              operator_name: "RANGE",
              operator_type: "TABLE_SCAN",
              operator_timing: 0.0015,
              operator_cardinality: 1_000,
              operator_rows_scanned: 1_000,
              children: []
            }
          ]
        }
      ]
    }

    assert [range, top_n] = Profile.slowest(profile, 2)
    assert range.name == "RANGE"
    assert range.path == [0, 0]
    assert top_n.name == "TOP_N"

    report = Profile.report(profile)
    assert report =~ "DuckDB query profile"
    assert report =~ "Rows scanned:"
    assert report =~ "RANGE"
  end
end
