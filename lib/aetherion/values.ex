defmodule Aetherion.Values do
  @moduledoc """
  Run-time values and their operators.

  Numbers, strings, booleans, lists and JSON are plain Elixir terms; JSON null
  is `nil`. Unit values are tagged, in one base unit each: `{:time, ms}`,
  `{:energy, joules}`, `{:power, watts}`, `{:carbon, grams}`,
  `{:data_rate, bytes_per_second}`, `{:percentage, percent}`, `{:users, count}`.
  A target is `{:target, name}`.

  Operators return `{:ok, value}`, or `:error` when the values do not fit,
  which the interpreter turns into a failed assert with no value (C141, C171).
  """

  alias PerfLang.AST

  @units [:time, :energy, :power, :carbon, :data_rate]
  @ordered @units ++ [:percentage, :users]

  @energy %{mJ: 0.001, J: 1, kJ: 1.0e3, MJ: 1.0e6, Wh: 3600, kWh: 3.6e6, MWh: 3.6e9}
  @power %{mW: 0.001, W: 1, kW: 1000}
  @carbon %{mgCO2e: 0.001, gCO2e: 1, kgCO2e: 1000}
  @data_rate %{"B/s": 1, "kB/s": 1.0e3, "MB/s": 1.0e6, "GB/s": 1.0e9}
  @milliseconds %{h: 3_600_000, m: 60_000, s: 1000, ms: 1}

  @doc "The value of a literal node."
  def literal(%AST.NumberLiteral{value: value}), do: value
  def literal(%AST.StringLiteral{value: value}), do: value
  def literal(%AST.BoolLiteral{value: value}), do: value
  def literal(%AST.TimeLiteral{} = time), do: {:time, milliseconds(time)}
  def literal(%AST.EnergyLiteral{value: value, unit: unit}), do: {:energy, value * @energy[unit]}
  def literal(%AST.PowerLiteral{value: value, unit: unit}), do: {:power, value * @power[unit]}
  def literal(%AST.CarbonLiteral{value: value, unit: unit}), do: {:carbon, value * @carbon[unit]}
  def literal(%AST.DataRateLiteral{value: value, unit: unit}), do: {:data_rate, value * @data_rate[unit]}
  def literal(%AST.PercentageLiteral{hundredths: hundredths}), do: {:percentage, hundredths / 100}
  def literal(%AST.UsersLiteral{value: value}), do: {:users, value}

  @doc "A Time literal in milliseconds."
  def milliseconds(%AST.TimeLiteral{parts: parts}) do
    Enum.reduce(parts, 0, &(&2 + &1.value * @milliseconds[&1.unit]))
  end

  # ---------- Arithmetic (C142, C145) ----------

  def arithmetic(:+, left, right) when is_binary(left) and is_binary(right), do: {:ok, left <> right}
  def arithmetic(:/, _left, right) when is_number(right) and right == 0, do: :error

  def arithmetic(:^, left, right) when is_number(left) and is_number(right) do
    {:ok, :math.pow(left, right)}
  rescue
    ArithmeticError -> :error
  end

  def arithmetic(:/, left, right) when is_number(left) and is_number(right), do: {:ok, left / right}
  def arithmetic(:+, left, right) when is_number(left) and is_number(right), do: {:ok, left + right}
  def arithmetic(:-, left, right) when is_number(left) and is_number(right), do: {:ok, left - right}
  def arithmetic(:*, left, right) when is_number(left) and is_number(right), do: {:ok, left * right}

  def arithmetic(op, {unit, left}, {unit, right}) when op in [:+, :-] and unit in @units,
    do: with({:ok, value} <- arithmetic(op, left, right), do: {:ok, {unit, value}})

  def arithmetic(:/, {unit, _left}, {unit, right}) when unit in @units and right == 0, do: :error
  def arithmetic(:/, {unit, left}, {unit, right}) when unit in @units, do: {:ok, left / right}

  def arithmetic(:/, {:energy, _joules}, {:time, ms}) when ms == 0, do: :error
  def arithmetic(:/, {:energy, joules}, {:time, ms}), do: {:ok, {:power, joules / (ms / 1000)}}
  def arithmetic(:*, {:power, watts}, {:time, ms}), do: {:ok, {:energy, watts * ms / 1000}}
  def arithmetic(:*, {:time, ms}, {:power, watts}), do: {:ok, {:energy, watts * ms / 1000}}

  def arithmetic(:*, {unit, value}, number) when unit in @units and is_number(number),
    do: {:ok, {unit, value * number}}

  def arithmetic(:*, number, {unit, value}) when unit in @units and is_number(number),
    do: {:ok, {unit, value * number}}

  def arithmetic(:/, {unit, value}, number) when unit in @units and is_number(number) and number != 0,
    do: {:ok, {unit, value / number}}

  def arithmetic(_op, _left, _right), do: :error

  @doc "Unary minus (C147)."
  def negate(number) when is_number(number), do: {:ok, -number}
  def negate({unit, value}) when unit in @units, do: {:ok, {unit, -value}}
  def negate(_value), do: :error

  # ---------- Comparison (C153) ----------

  def equal?(left, right), do: left == right

  def compare(op, left, right) when is_number(left) and is_number(right),
    do: {:ok, apply(Kernel, op, [left, right])}

  def compare(op, {unit, left}, {unit, right}) when unit in @ordered,
    do: {:ok, apply(Kernel, op, [left, right])}

  def compare(_op, _left, _right), do: :error

  @doc "min or max of two numbers, or of two values of one unit type (C144)."
  def limit(fun, left, right) when is_number(left) and is_number(right),
    do: {:ok, apply(Kernel, fun, [left, right])}

  def limit(fun, {unit, left}, {unit, right}) when unit in @ordered,
    do: {:ok, {unit, apply(Kernel, fun, [left, right])}}

  def limit(_fun, _left, _right), do: :error

  # ---------- Text (C177) ----------

  @suffix %{
    time: "ms",
    energy: "J",
    power: "W",
    carbon: "gCO2e",
    data_rate: "B/s",
    percentage: "%",
    users: "vu"
  }

  @doc """
  The text of a value, for toString() (C177). A Float keeps its decimal point, a unit value
  is written in its base unit like the report, a JSON string gives its content and other JSON
  its compact text. JSON null, and a value with no text form, give `:error`.
  """
  def to_text(value) when is_binary(value), do: {:ok, value}
  def to_text(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  def to_text(value) when is_float(value), do: {:ok, Float.to_string(value)}
  def to_text(value) when is_boolean(value), do: {:ok, Atom.to_string(value)}
  def to_text({unit, amount}) when unit in @ordered, do: {:ok, unit_text(amount) <> @suffix[unit]}
  def to_text(value) when is_list(value) or is_map(value), do: {:ok, JSON.encode!(value)}
  def to_text(_value), do: :error

  # At most three decimals, as in the report, and no ".0" on a whole value.
  defp unit_text(amount) when is_integer(amount), do: Integer.to_string(amount)

  defp unit_text(amount) do
    rounded = Float.round(amount, 3)

    if rounded == Float.round(rounded),
      do: rounded |> trunc() |> Integer.to_string(),
      else: Float.to_string(rounded)
  end

  # ---------- Reports ----------

  @doc "A value for the report and the summary."
  def show({:time, ms}), do: "#{round_to(ms)}ms"
  def show({:energy, joules}), do: "#{round_to(joules)}J"
  def show({:power, watts}), do: "#{round_to(watts)}W"
  def show({:carbon, grams}), do: "#{round_to(grams)}gCO2e"
  def show({:data_rate, bytes}), do: "#{round_to(bytes)}B/s"
  def show({:percentage, percent}), do: "#{round_to(percent)}%"
  def show({:users, count}), do: "#{count}vu"
  def show({:target, name}), do: name
  def show(number) when is_float(number), do: to_string(round_to(number))
  def show(value) when is_binary(value), do: inspect(value)
  def show(value), do: inspect(value)

  @doc "A value for the JSON summary: its number, in the units of the README."
  def plain({_unit, value}), do: value
  def plain(value), do: value

  def round_to(number) when is_integer(number), do: number
  def round_to(number) when is_float(number), do: Float.round(number, 3)
end
