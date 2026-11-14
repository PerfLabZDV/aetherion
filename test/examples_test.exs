defmodule PerfLang.ExamplesTest do
  use ExUnit.Case, async: true

  alias PerfLang.AST

  @fixture Path.expand("fixtures/full_suite.perf", __DIR__)

  test "every example from perflang.ebnf parses as one suite" do
    assert {:ok, %AST.TestSuite{name: "ShopCheckout"} = ast} = PerfLang.parse_file(@fixture)

    assert %AST.Config{
             sections: [
               %AST.Sut{targets: targets},
               %AST.Output{settings: [_, _, _]},
               %AST.Monitoring{},
               %AST.Runs{settings: [%AST.RunsCount{}, %AST.RunsCooldown{}, %AST.RunsDiscard{}]}
             ]
           } =
             ast.config

    assert Enum.map(targets, & &1.name) == [
             "euCentral",
             "usEast",
             "euCentralDb",
             "euCentralGpu",
             "euCentralPlug"
           ]

    assert length(ast.functions) == 5
    assert [%AST.Test{name: "BrowseProducts"}, %AST.Test{name: "Checkout"}] = ast.tests

    assert [
             %AST.Warmup{},
             %AST.ThinkTime{},
             %AST.RequestTimeout{},
             %AST.Curves{},
             %AST.Stages{},
             %AST.Distribution{},
             %AST.Retry{},
             %AST.StopIf{},
             %AST.StopIf{},
             %AST.StopIf{}
           ] = ast.load.settings
  end

  test "every node is a valid AST struct with a {line, column} location" do
    {:ok, ast} = PerfLang.parse_file(@fixture)

    for node <- nodes(ast) do
      assert {line, col} = node.loc, "missing loc in #{inspect(node.__struct__)}"
      assert is_integer(line) and is_integer(col)
    end
  end

  test "errors carry the file name" do
    path = Path.join(System.tmp_dir!(), "broken.perf")
    File.write!(path, "TestSuite S {\n  Load { warmup 2; }\n}")
    assert {:error, e} = PerfLang.parse_file(path)
    assert PerfLang.Error.format(e) == "#{path}:2:17: unexpected number 2"
  end

  defp nodes(%AST.TimePart{}), do: []

  defp nodes(%{__struct__: _} = node),
    do: [node | node |> Map.from_struct() |> Map.values() |> Enum.flat_map(&nodes/1)]

  defp nodes(list) when is_list(list), do: Enum.flat_map(list, &nodes/1)
  defp nodes(_), do: []
end
