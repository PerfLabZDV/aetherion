defmodule PerfLang.Error do
  @moduledoc """
  A lexical, syntax, validation or semantic error with its position.

  `stage` is `:lexer`, `:parser`, `:validator` or `:semantic`. `line` and `column` start at 1.
  """
  defexception [:stage, :message, :line, :column, :file]

  @type t :: %__MODULE__{
          stage: :lexer | :parser | :validator | :semantic,
          message: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          file: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{} = e), do: format(e)

  @doc "Formats the error as `file:line:column: message`."
  def format(%__MODULE__{file: file, line: line, column: column, message: message}) do
    prefix = if file, do: "#{file}:", else: ""
    "#{prefix}#{line}:#{column}: #{message}"
  end
end
