defmodule Aetherion.Source do
  @moduledoc "The source text of an expression, for the report (C121, C131)."

  alias PerfLang.AST

  def text(%AST.Binary{op: op, left: left, right: right}), do: "#{text(left)} #{op} #{text(right)}"
  def text(%AST.Unary{op: op, operand: operand}), do: "#{op}#{text(operand)}"
  def text(%AST.Var{name: name}), do: name
  def text(%AST.Http{}), do: "http"
  def text(%AST.Member{object: object, name: name}), do: "#{text(object)}.#{name}"
  def text(%AST.Index{object: object, index: index}), do: "#{text(object)}[#{text(index)}]"

  def text(%AST.Call{callee: callee, args: args}),
    do: "#{text(callee)}(#{Enum.map_join(args, ", ", &text/1)})"

  def text(%AST.ListOperation{receiver: receiver, op: op, init: init, function: function}) do
    args = if init, do: "#{text(init)}, #{text(function)}", else: text(function)
    "#{text(receiver)}.#{op}(#{args})"
  end

  def text(%AST.Lambda{params: params, body: body}) do
    "\\(#{Enum.map_join(params, ", ", & &1.name)}) -> #{text(body)}"
  end

  def text(%AST.Metric{group: group, measurement: measurement, argument: argument, target: target}) do
    prefix = if target, do: "#{text(target)}.", else: ""
    "#{prefix}#{group}.#{measurement}(#{if argument, do: argument.raw})"
  end

  def text(%AST.Match{}), do: "match"
  def text(%AST.JsonObject{}), do: "{...}"
  def text(%AST.JsonArray{}), do: "[...]"
  def text(%AST.Null{}), do: "null"
  def text(%AST.StringLiteral{value: value}), do: inspect(value)
  def text(%AST.BoolLiteral{value: value}), do: to_string(value)
  def text(%{raw: raw}) when is_binary(raw), do: raw

  @doc "The metrics and machine readings in an expression, in source order."
  def measured(%AST.Metric{} = node), do: [node]

  def measured(%AST.Call{callee: %AST.Member{object: %AST.Member{name: name}}} = node)
      when name in ["cpu", "mem", "disk", "gpu", "power"],
      do: [node]

  def measured(%{__struct__: _} = node) do
    node |> Map.from_struct() |> Map.delete(:loc) |> Map.values() |> Enum.flat_map(&measured/1)
  end

  def measured(list) when is_list(list), do: Enum.flat_map(list, &measured/1)
  def measured(_other), do: []
end
