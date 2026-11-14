defmodule PerfLang.Lexer do
  @moduledoc """
  Turns PerfLang source into tokens for the parser.

  The token rules live in `src/perflang_lexer.xrl` (leex). This module
  runs that lexer, computes the exact `{line, column}` of every token,
  drops whitespace and comments, converts literal text into structured
  values and turns the lexer's error tokens into `PerfLang.Error`s.

  Tokens are `{category, {line, column}, value}`:

    * identifiers and keywords: the name as a string
    * `time_lit`: `{raw, [{number_text, unit}]}`, e.g. `{"7m30s", [{"7", :m}, {"30", :s}]}`
    * `energy_lit`, `power_lit`, `carbon_lit`: `{raw, number_text, unit}`
    * `users_lit`, `iterations_lit`, `percentage_lit`: `{raw, number_text}`
    * `int_lit`, `float_lit`: the number text
    * `string_lit`, `raw_string_lit`: the string content, escapes resolved
    * punctuation: the symbol as a string
  """

  alias PerfLang.Error

  @type token :: {atom(), {pos_integer(), pos_integer()}, term()}

  @doc "Tokenizes `source`. Returns `{:ok, tokens}` or `{:error, %PerfLang.Error{}}`."
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, Error.t()}
  def tokenize(source) when is_binary(source) do
    case :perflang_lexer.string(String.to_charlist(source)) do
      {:ok, raw_tokens, _end_line} ->
        walk(raw_tokens, {1, 1}, [])

      {:error, {line, _module, reason}, _} ->
        # Not expected: every input matches some rule in the .xrl.
        {:error, %Error{stage: :lexer, line: line, column: 1, message: inspect(reason)}}
    end
  end

  @doc "Like `tokenize/1`, but returns the end-of-input position too."
  def tokenize_with_end(source) do
    with {:ok, tokens} <- tokenize(source) do
      {:ok, tokens, end_position(source)}
    end
  end

  defp walk([], _pos, acc), do: {:ok, Enum.reverse(acc)}

  defp walk([{category, _line, chars} | rest], pos, acc)
       when category in [:whitespace, :comment] do
    walk(rest, advance(pos, chars), acc)
  end

  defp walk([{:lex_error, _line, {kind, chars}} | _], {line, col}, _acc) do
    {:error, %Error{stage: :lexer, line: line, column: col, message: error_message(kind, chars)}}
  end

  defp walk([{category, _line, chars} | rest], pos, acc) do
    walk(rest, advance(pos, chars), [{category, pos, value(category, chars)} | acc])
  end

  defp advance(pos, []), do: pos
  defp advance({line, _col}, [?\n | rest]), do: advance({line + 1, 1}, rest)
  defp advance({line, col}, [_ | rest]), do: advance({line, col + 1}, rest)

  defp end_position(source), do: advance({1, 1}, String.to_charlist(source))

  # ---------- Token values ----------

  defp value(:time_lit, chars) do
    raw = List.to_string(chars)
    parts = Regex.scan(~r/(\d+(?:\.\d+)?)(ms|h|m|s)/, raw, capture: :all_but_first)
    {raw, for([num, unit] <- parts, do: {num, String.to_atom(unit)})}
  end

  defp value(category, chars) when category in [:energy_lit, :power_lit, :carbon_lit] do
    raw = List.to_string(chars)
    [_, num, unit] = Regex.run(~r/^(\d+(?:\.\d+)?)(.+)$/, raw)
    {raw, num, String.to_existing_atom(unit)}
  end

  defp value(:carbon_intensity_lit, chars) do
    raw = List.to_string(chars)
    {raw, String.trim_trailing(raw, "gCO2e/kWh")}
  end

  defp value(:users_lit, chars) do
    raw = List.to_string(chars)
    {raw, String.trim_trailing(raw, "vu")}
  end

  defp value(:iterations_lit, chars) do
    raw = List.to_string(chars)
    {raw, raw |> String.trim_trailing("/vu") |> String.trim_trailing("iter")}
  end

  defp value(:percentage_lit, chars) do
    raw = List.to_string(chars)
    {raw, String.trim_trailing(raw, "%")}
  end

  defp value(:string_lit, chars) do
    chars |> Enum.slice(1..-2//1) |> unescape([]) |> List.to_string()
  end

  defp value(:raw_string_lit, chars) do
    chars |> Enum.slice(3..-4//1) |> List.to_string()
  end

  defp value(_category, chars), do: List.to_string(chars)

  # The .xrl only accepts these four escapes in a string_lit token.
  defp unescape([], acc), do: Enum.reverse(acc)
  defp unescape([?\\, ?n | rest], acc), do: unescape(rest, [?\n | acc])
  defp unescape([?\\, ?t | rest], acc), do: unescape(rest, [?\t | acc])
  defp unescape([?\\, c | rest], acc), do: unescape(rest, [c | acc])
  defp unescape([c | rest], acc), do: unescape(rest, [c | acc])

  # Units the energy/power/carbon atoms are created from; String.to_existing_atom/1
  # above relies on them existing.
  @units [:mJ, :J, :kJ, :MJ, :Wh, :kWh, :MWh, :mW, :W, :kW, :mgCO2e, :gCO2e, :kgCO2e]
  @doc false
  def units, do: @units

  # ---------- Error messages ----------

  defp error_message(:illegal_character, [c]) do
    "unexpected character #{inspect(<<c::utf8>>)}" <>
      case c do
        ?% -> " (write a percentage without a space before %, e.g. 70%)"
        ?' -> " (strings use double quotes)"
        _ -> ""
      end
  end

  defp error_message(:unterminated_comment, _), do: "unterminated block comment, expected */"
  defp error_message(:unterminated_raw_string, _), do: ~s(unterminated raw string, expected """)

  defp error_message(:unterminated_string, _),
    do: ~s(unterminated string, expected " before the end of the line (use """...""" for multi-line strings\))

  defp error_message(:bad_escape, chars) do
    bad = chars |> List.to_string() |> then(&Regex.run(~r/\\([^"\\nt])/, &1)) |> Enum.at(0)
    ~s(invalid escape sequence #{bad} in string; allowed escapes are \\" \\\\ \\n \\t)
  end

  defp error_message(:fractional_users, chars),
    do: "virtual users must be a whole number, got #{List.to_string(chars)}"

  defp error_message(:fractional_iterations, chars),
    do: "an iteration count must be a whole number, got #{List.to_string(chars)}"

  defp error_message(:percentage_decimals, chars),
    do: "a percentage has at most two decimal places, got #{List.to_string(chars)}"

  defp error_message(:underscore_identifier, chars),
    do: "identifiers must start with a letter, got #{List.to_string(chars)}"

  defp error_message(:unknown_unit, chars) do
    text = List.to_string(chars)
    [_, num, suffix] = Regex.run(~r/^(\d+(?:\.\d+)?)(.*)$/, text)

    "invalid literal #{text}: #{inspect(suffix)} is not a unit after #{num} " <>
      "(Time: h m s ms, combined largest first like 7m30s; Energy: mJ J kJ MJ Wh kWh MWh; " <>
      "Power: mW W kW; Carbon: mgCO2e gCO2e kgCO2e; VirtualUsers: vu; iteration count: iter, or iter/vu per user)"
  end
end
