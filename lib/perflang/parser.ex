defmodule PerfLang.Parser do
  @moduledoc """
  Parses PerfLang tokens into a `PerfLang.AST.TestSuite`, or into a
  `PerfLang.AST.Config` for an external configuration file (C157).

  The grammar lives in `src/perflang_parser.yrl` (yecc, LALR(1)). This
  module feeds it the tokens from `PerfLang.Lexer` and turns yecc's
  errors into `PerfLang.Error`s with a line, a column and a readable
  message.
  """

  alias PerfLang.{Error, Lexer}

  @doc "Parses source text. Returns `{:ok, ast}` or `{:error, %PerfLang.Error{}}`."
  @spec parse(String.t()) :: {:ok, PerfLang.AST.TestSuite.t()} | {:error, Error.t()}
  def parse(source) when is_binary(source) do
    with {:ok, tokens, end_pos} <- Lexer.tokenize_with_end(source) do
      parse_tokens(tokens, end_pos)
    end
  end

  @doc "Parses an external configuration file (C157). Returns `{:ok, config}` or `{:error, %PerfLang.Error{}}`."
  @spec parse_config(String.t()) :: {:ok, PerfLang.AST.Config.t()} | {:error, Error.t()}
  def parse_config(source) when is_binary(source) do
    with {:ok, tokens, end_pos} <- Lexer.tokenize_with_end(source) do
      run([{:config_file, {1, 1}, ""} | tokens], tokens, end_pos)
    end
  end

  @doc "Parses a token list from `PerfLang.Lexer`."
  def parse_tokens(tokens, end_pos \\ nil), do: run(tokens, tokens, end_pos || last_position(tokens))

  # `tokens` leaves out config_file, which is not in the source.
  defp run(input, tokens, end_pos) do
    case :perflang_parser.parse(input ++ [{:"$end", end_pos}]) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {{line, column}, :perflang_parser, message}} ->
        {:error,
         %Error{
           stage: :parser,
           line: line,
           column: column,
           message: describe(message, tokens, {line, column})
         }}
    end
  end

  defp last_position([]), do: {1, 1}
  defp last_position(tokens), do: tokens |> List.last() |> elem(1)

  # yecc reports ["syntax error before: ", TokenText] at the offending token.
  defp describe([~c"syntax error before: ", _], tokens, pos) do
    case Enum.find_index(tokens, fn t -> elem(t, 1) == pos end) do
      nil ->
        "unexpected end of input"

      i ->
        token = Enum.at(tokens, i)
        previous = if i > 0, do: Enum.at(tokens, i - 1)
        "unexpected #{describe_token(token)}" <> hint(token, previous)
    end
  end

  defp describe(message, _tokens, _pos), do: IO.chardata_to_string(message)

  defp describe_token({:identifier, _, name}), do: "name #{name}"
  defp describe_token({:string_lit, _, _}), do: "string"
  defp describe_token({:raw_string_lit, _, _}), do: "raw string"
  defp describe_token({:int_lit, _, text}), do: "number #{text}"
  defp describe_token({:float_lit, _, text}), do: "number #{text}"

  defp describe_token({category, _, {raw, _}})
       when category in [:time_lit, :users_lit, :iterations_lit, :percentage_lit, :carbon_intensity_lit],
       do: "#{literal_kind(category)} #{raw}"

  defp describe_token({category, _, {raw, _, _}}), do: "#{literal_kind(category)} #{raw}"
  defp describe_token({_, _, text}), do: inspect(text)

  defp literal_kind(:time_lit), do: "Time"
  defp literal_kind(:users_lit), do: "VirtualUsers"
  defp literal_kind(:iterations_lit), do: "iteration count"
  defp literal_kind(:percentage_lit), do: "Percentage"
  defp literal_kind(:energy_lit), do: "Energy"
  defp literal_kind(:power_lit), do: "Power"
  defp literal_kind(:carbon_lit), do: "Carbon"
  defp literal_kind(:data_rate_lit), do: "DataRate"
  defp literal_kind(:carbon_intensity_lit), do: "carbon intensity"

  @reserved ~w(let mut fn if else while for in match return assert check map filter fold foldl foldr
               true false null TestSuite Test Load Setup Actions Verify Cleanup Functions Config
               latency throughput errors energy power carbon asserts checks http)a

  # Tokens after which a name is expected.
  @name_expected [:let, :mut, :fn, :for, :TestSuite, :Test, :., :"\\"]

  defp hint({:Config, _, _}, previous)
       when not (is_tuple(previous) and elem(previous, 0) in @name_expected),
       do: " (Config is the first block in the TestSuite, before Functions, Load and the Tests; C97)"

  defp hint({:carbon_intensity_lit, _, _}, _previous),
    do: " (a carbon intensity is only the carbonIntensity setting in monitoring; C161)"

  defp hint({:iterations_lit, _, _}, _previous),
    do:
      " (an iteration count is only a stage length, e.g. 1vu for 10iter or 20vu for 1iter/vu; C101, C102, C175)"

  defp hint({:Load, _, _}, _previous),
    do:
      " (Load goes either in the TestSuite before the first Test, or as the first block of every Test, not both; C10, C11)"

  defp hint({category, _, _}, {previous, _, _})
       when category in @reserved and previous in @name_expected,
       do: " (#{category} is a reserved word and cannot be used as a name; C77)"

  defp hint(_token, _previous), do: ""
end
