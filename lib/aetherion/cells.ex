defmodule Aetherion.Cells do
  @moduledoc """
  The storage of `let mut` lists, the only values `add` changes (C137).

  A shared cell lives in the Test's ETS table, so every virtual user sees it and
  each `add` is atomic: one insert under its own key, so no value is lost. A
  local cell lives in the process dictionary of the one process that declared
  it, since an Actions variable belongs to one iteration.
  """

  @doc "A new cell holding `list`, in `table`, or in this process when `table` is nil."
  def new(list, nil) do
    ref = make_ref()
    Process.put({__MODULE__, ref}, Enum.reverse(list))
    {:cell, :local, ref}
  end

  def new(list, table) do
    cell = {:cell, table, :erlang.unique_integer([:positive])}
    write(cell, list)
    cell
  end

  def cell?({:cell, _table, _id}), do: true
  def cell?(_value), do: false

  def read({:cell, :local, ref}), do: Enum.reverse(Process.get({__MODULE__, ref}, []))

  def read({:cell, table, id}) do
    table |> :ets.select([{{{id, :_}, :"$1"}, [], [:"$1"]}])
  end

  def add({:cell, :local, ref}, value) do
    Process.put({__MODULE__, ref}, [value | Process.get({__MODULE__, ref}, [])])
    :ok
  end

  def add({:cell, table, id}, value) do
    :ets.insert(table, {{id, :erlang.unique_integer([:monotonic])}, value})
    :ok
  end

  def write({:cell, :local, ref}, list) do
    Process.put({__MODULE__, ref}, Enum.reverse(list))
    :ok
  end

  def write({:cell, table, id} = cell, list) do
    :ets.match_delete(table, {{id, :_}, :_})
    Enum.each(list, &add(cell, &1))
  end
end
