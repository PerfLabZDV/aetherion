ExUnit.start()

defmodule PerfLang.TestHelpers do
  alias PerfLang.AST

  @doc "Wraps statements in a minimal valid suite."
  def suite(statements, load \\ "") do
    """
    TestSuite S {
      Load { #{load} }
      Test T {
        Actions { #{statements} }
        Verify { }
      }
    }
    """
  end

  def statements!(source) do
    %AST.TestSuite{tests: [%AST.Test{actions: %AST.Phase{statements: stmts}}]} =
      PerfLang.parse!(suite(source))

    stmts
  end

  def expr!(source) do
    [%AST.Let{value: value}] = statements!("let x = #{source};")
    value
  end

  def load_settings!(load) do
    %AST.TestSuite{load: %AST.Load{settings: settings}} = PerfLang.parse!(suite("", load))
    settings
  end

  def parse_error(source) do
    {:error, %PerfLang.Error{} = e} = PerfLang.parse(source)
    e
  end

  @doc "Strips locations and types the Analyzer has not filled in, for comparing tree shapes."
  def strip(%{__struct__: _} = node) do
    node
    |> Map.from_struct()
    |> Map.delete(:loc)
    |> Map.reject(&(&1 == {:type, nil}))
    |> Map.new(fn {k, v} -> {k, strip(v)} end)
  end

  def strip(list) when is_list(list), do: Enum.map(list, &strip/1)
  def strip(other), do: other

  @doc "Renders an expression as a fully parenthesised string, to check precedence."
  def show(%AST.Binary{op: op, left: l, right: r}), do: "(#{show(l)} #{op} #{show(r)})"
  def show(%AST.Unary{op: op, operand: o}), do: "(#{op}#{show(o)})"
  def show(%AST.Var{name: n}), do: n
  def show(%AST.Http{}), do: "http"
  def show(%AST.NumberLiteral{raw: raw}), do: raw
  def show(%AST.Member{object: o, name: n}), do: "#{show(o)}.#{n}"
  def show(%AST.Call{callee: c, args: a}), do: "#{show(c)}(#{Enum.map_join(a, ", ", &show/1)})"
  def show(%AST.Index{object: o, index: i}), do: "#{show(o)}[#{show(i)}]"
  def show(%AST.StringLiteral{value: v}), do: inspect(v)
  def show(%AST.BoolLiteral{value: v}), do: to_string(v)
  def show(%{raw: raw}) when is_binary(raw), do: raw
end
