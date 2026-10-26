defmodule QuackDB.ProfileTest do
  use ExUnit.Case, async: true

  alias QuackDB.Profile
  alias QuackDB.Profile.Operator

  @analyze_profile %{
    "io" => %{"total_bytes_read" => 0, "total_bytes_written" => 0},
    "optimizer" => %{"join_order" => 0.002, "total_time" => 0.003},
    "parser" => %{"total_time" => 0.0006},
    "physical_planner" => %{
      "column_binding" => 0.0001,
      "create_plan" => 0.0004,
      "resolve_types" => 1.25e-7,
      "total_time" => 0.0005
    },
    "planner" => %{"binding_time" => 0.0024, "total_time" => 0.0025},
    "query" => %{
      "cpu_time" => 0.002,
      "sql" => "SELECT 1",
      "total_intermediate_rows" => 2983,
      "total_rows_scanned" => 1_000,
      "total_time" => 0.004
    },
    "system" => %{"peak_buffer_memory" => 1_736_704, "unknown_metric" => 1},
    "operator" => [
      %{
        "type" => "TOP_N",
        "timing" => 0.0005,
        "intermediate_rows" => 5,
        "extra_info" => %{"Top" => "5", "Projections" => ["i", "bucket"]},
        "children" => [
          %{
            "type" => "TABLE_SCAN",
            "timing" => 0.0015,
            "intermediate_rows" => 1_000,
            "rows_scanned" => 1_000,
            "extra_info" => %{"Function" => "RANGE"},
            "children" => []
          }
        ]
      }
    ]
  }

  test "decodes DuckDB 2.0 grouped profiles and preserves open-ended string keys" do
    assert {:ok, profile} = Profile.from_map(@analyze_profile)

    assert profile.query.total_time == 0.004
    assert profile.query.total_rows_scanned == 1_000
    assert profile.planner.binding_time == 0.0024
    assert profile.physical_planner.create_plan == 0.0004
    assert profile.system.peak_buffer_memory == 1_736_704
    assert profile.optimizer == %{"join_order" => 0.002, "total_time" => 0.003}

    assert [%Operator{type: "TOP_N", children: [%Operator{} = scan]} = top_n] = profile.operators
    assert top_n.extra_info == %{"Top" => "5", "Projections" => ["i", "bucket"]}
    assert scan.rows_scanned == 1_000
    assert scan.children == []
  end

  test "profile schemas export recursive operators as local references" do
    assert Operator.schema()["properties"]["children"]["items"] == %{"$ref" => "#"}

    schema = Profile.schema()

    assert schema["properties"]["operator"]["items"]["properties"]["children"]["items"] ==
             %{"$ref" => "#/properties/operator/items"}

    assert JSON.decode!(JSON.encode!(schema)) == schema
  end

  test "malformed known profile fields fail instead of leaking undecoded values" do
    for input <- [
          %{"query" => %{"total_time" => "fast"}},
          %{"operator" => "invalid"},
          %{"operator" => [%{"timing" => "fast"}]}
        ] do
      assert {:error, %JSONCodec.Error{}} = Profile.from_map(input)
    end
  end

  test "flattens and reports slow operators" do
    {:ok, profile} = Profile.from_map(@analyze_profile)

    assert [scan, top_n] = Profile.slowest(profile, 2)
    assert scan.name == "TABLE_SCAN"
    assert scan.path == [0, 0]
    assert scan.timing_percent == 75.0
    assert top_n.name == "TOP_N"

    report = Profile.report(profile)
    assert report =~ "DuckDB query profile"
    assert report =~ "Rows scanned:   1,000"
    assert report =~ "TABLE_SCAN"
  end

  test "plain plans name their operators" do
    assert {:ok, profile} =
             Profile.from_map(%{
               "operator" => [%{"name" => "PROJECTION", "extra_info" => %{}, "children" => []}]
             })

    assert [%{name: "PROJECTION", timing: nil}] = Profile.flatten(profile)
  end
end
