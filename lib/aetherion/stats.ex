defmodule Aetherion.Stats do
  @moduledoc """
  Statistics across runs (C180).

  Every metric is computed once per run, and the statistics describe those
  per-run values: a p95 across ten runs is the description of ten p95s, not
  the p95 of every latency of every run, which would hide how much the runs
  differ. `aggregate/1` takes the summaries of one Test from the counted runs
  and gives the same shape, with a description in place of every number.

  A description has n, mean, sd (sample standard deviation), cv (sd over
  mean, as a number from 0 to 100), median, min, max and ci95, the 95%
  confidence interval of the mean from Student's t. With one value, sd, cv and
  ci95 are nil, and so is cv when the mean is 0. A value missing in some runs,
  such as a latency with no response, is described over the runs that have it,
  and n says how many.
  """

  # Student's t, two-sided 95%, for 1 to 30 degrees of freedom.
  @t975 {12.7062, 4.3027, 3.1824, 2.7764, 2.5706, 2.4469, 2.3646, 2.3060, 2.2622, 2.2281, 2.2010, 2.1788,
         2.1604, 2.1448, 2.1314, 2.1199, 2.1098, 2.1009, 2.0930, 2.0860, 2.0796, 2.0739, 2.0687, 2.0639,
         2.0595, 2.0555, 2.0518, 2.0484, 2.0452, 2.0423}
  @z975 1.959963984540054

  # Sample counts say how a value was measured, not what it measured.
  @skip [:samples]

  @doc "The description of a list of numbers, or nil for none."
  def describe([]), do: nil

  def describe(values) do
    n = length(values)
    mean = Enum.sum(values) / n
    sorted = Enum.sort(values)

    base = %{
      n: n,
      mean: mean,
      sd: nil,
      cv: nil,
      median: median(sorted, n),
      min: hd(sorted),
      max: List.last(sorted),
      ci95: nil
    }

    if n < 2 do
      base
    else
      sd = :math.sqrt(Enum.sum(Enum.map(values, &((&1 - mean) * (&1 - mean)))) / (n - 1))
      half = t975(n - 1) * sd / :math.sqrt(n)
      cv = if mean == 0, do: nil, else: sd / abs(mean) * 100
      %{base | sd: sd, cv: cv, ci95: %{low: mean - half, high: mean + half}}
    end
  end

  defp median(sorted, n) when rem(n, 2) == 1, do: Enum.at(sorted, div(n, 2))
  defp median(sorted, n), do: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2

  @doc "Student's t for a two-sided 95% interval; above 30 degrees of freedom by its Cornish-Fisher expansion."
  def t975(df) when df in 1..30, do: elem(@t975, df - 1)

  def t975(df) do
    z = @z975
    g1 = (:math.pow(z, 3) + z) / 4
    g2 = (5 * :math.pow(z, 5) + 16 * :math.pow(z, 3) + 3 * z) / 96
    g3 = (3 * :math.pow(z, 7) + 19 * :math.pow(z, 5) + 17 * :math.pow(z, 3) - 15 * z) / 384
    z + g1 / df + g2 / (df * df) + g3 / (df * df * df)
  end

  @doc """
  The summaries of one Test from several runs (Report.test_summary/1), merged:
  its metrics, endpoints, targets and load generator readings.
  """
  def aggregate(summaries) do
    %{
      metrics: merge(Enum.map(summaries, & &1.metrics)),
      endpoints:
        keyed(summaries, :endpoints, &{&1.target, &1.method, &1.url}, fn {target, method, url}, merged ->
          Map.merge(merged || %{}, %{target: target, method: method, url: url})
        end),
      targets:
        keyed(summaries, :targets, & &1.name, fn name, merged -> Map.put(merged || %{}, :name, name) end),
      loadGenerator: merge(Enum.map(summaries, & &1.loadGenerator)),
      workers:
        keyed(summaries, :workers, & &1.name, fn name, merged -> Map.put(merged || %{}, :name, name) end)
    }
  end

  # A list whose items are matched across runs by a key, such as an endpoint
  # by target, method and path.
  defp keyed(summaries, field, key, build) do
    per_run = Enum.map(summaries, &Map.new(Map.fetch!(&1, field), fn item -> {key.(item), item} end))
    keys = summaries |> Enum.flat_map(&Map.fetch!(&1, field)) |> Enum.map(key) |> Enum.uniq()

    for k <- keys do
      merged = merge(Enum.map(per_run, &Map.get(&1, k)))
      build.(k, if(merged == :skip, do: nil, else: merged))
    end
  end

  @doc "Values of one shape from several runs, merged into that shape with a description at every number."
  def merge(items) do
    present = Enum.reject(items, &is_nil/1)

    cond do
      present == [] ->
        nil

      Enum.all?(present, &is_number/1) ->
        describe(present)

      Enum.all?(present, &is_map/1) ->
        keys = present |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

        for key <- keys,
            key not in @skip,
            merged = merge(Enum.map(present, &Map.get(&1, key))),
            merged != :skip,
            into: %{},
            do: {key, merged}

      true ->
        :skip
    end
  end
end
