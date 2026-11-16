defmodule PerfLang.LexerTest do
  use ExUnit.Case, async: true

  alias PerfLang.Lexer

  defp tokens(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    tokens
  end

  defp categories(source), do: source |> tokens() |> Enum.map(&elem(&1, 0))
  defp values(source), do: source |> tokens() |> Enum.map(&elem(&1, 2))

  defp error(source) do
    {:error, %PerfLang.Error{stage: :lexer} = e} = Lexer.tokenize(source)
    e
  end

  describe "positions" do
    test "line and column of every token, after whitespace and comments" do
      source = "let x = 1;\n  // comment\n  /* a\n  b */ y"

      assert Enum.map(tokens(source), &elem(&1, 1)) ==
               [{1, 1}, {1, 5}, {1, 7}, {1, 9}, {1, 10}, {4, 8}]
    end

    test "columns continue after a multi-line raw string" do
      [_, {:identifier, pos, "y"}] = tokens(~s("""a\nbc""" y))
      assert pos == {2, 7}
    end

    test "columns count characters, not bytes" do
      [_, {:identifier, pos, _}] = tokens(~s("é" y))
      assert pos == {1, 5}
    end
  end

  describe "Time literals (C14, C15, C29, C57, C81)" do
    test "single units" do
      assert values("500ms 1.5s 2m 0.5h") == [
               {"500ms", [{"500", :ms}]},
               {"1.5s", [{"1.5", :s}]},
               {"2m", [{"2", :m}]},
               {"0.5h", [{"0.5", :h}]}
             ]
    end

    test "combined units, largest first, one token" do
      assert values("7m30s 1h15m 2s500ms 1h2m3s4ms") == [
               {"7m30s", [{"7", :m}, {"30", :s}]},
               {"1h15m", [{"1", :h}, {"15", :m}]},
               {"2s500ms", [{"2", :s}, {"500", :ms}]},
               {"1h2m3s4ms", [{"1", :h}, {"2", :m}, {"3", :s}, {"4", :ms}]}
             ]
    end

    test "decimals in any part are lexed; C81 is checked after parsing" do
      assert values("1m30.5s 1.5m30s") == [
               {"1m30.5s", [{"1", :m}, {"30.5", :s}]},
               {"1.5m30s", [{"1.5", :m}, {"30", :s}]}
             ]
    end

    test "out-of-order or repeated units are rejected" do
      assert error("30s7m").message =~ "is not a unit"
      assert error("1m1m").message =~ "is not a unit"
    end
  end

  describe "longest-match units (C41)" do
    test "ms, mJ, mW, MJ, MWh are single units" do
      assert categories("5ms 5mJ 5mW 5MJ 5MWh 5m") ==
               [:time_lit, :energy_lit, :power_lit, :energy_lit, :energy_lit, :time_lit]
    end

    test "energy, power and carbon literals" do
      assert values("10J 0.5kWh 2kW 2.5gCO2e 1mgCO2e 3kgCO2e") == [
               {"10J", "10", :J},
               {"0.5kWh", "0.5", :kWh},
               {"2kW", "2", :kW},
               {"2.5gCO2e", "2.5", :gCO2e},
               {"1mgCO2e", "1", :mgCO2e},
               {"3kgCO2e", "3", :kgCO2e}
             ]
    end

    test "data rate literals are one token, in bytes per second (C186)" do
      assert values("1B/s 2.5kB/s 50MB/s 1GB/s") == [
               {"1B/s", "1", :"B/s"},
               {"2.5kB/s", "2.5", :"kB/s"},
               {"50MB/s", "50", :"MB/s"},
               {"1GB/s", "1", :"GB/s"}
             ]

      assert categories("50MB/s") == [:data_rate_lit]
      assert error("5Mbit/s").message =~ "DataRate: B/s kB/s MB/s GB/s"
      assert error("5mB/s").message =~ ~s("mB" is not a unit)
      assert error("5MB").message =~ ~s("MB" is not a unit)
    end

    test "units are case-sensitive" do
      assert error("5j").message =~ ~s("j" is not a unit)
      assert error("5KW").message =~ ~s("KW" is not a unit)
    end

    test "unknown suffix after a number" do
      e = error("let x = 5x;")
      assert {e.line, e.column} == {1, 9}
      assert e.message =~ ~s(invalid literal 5x: "x" is not a unit)
    end
  end

  describe "VirtualUsers (C94, C95)" do
    test "whole numbers with vu" do
      assert values("50vu 0vu") == [{"50vu", "50"}, {"0vu", "0"}]
    end

    test "fractional users are rejected" do
      assert error("2.5vu").message =~ "whole number"
    end
  end

  describe "iteration counts (C102)" do
    test "whole numbers with iter" do
      assert values("10iter 0iter") == [{"10iter", "10"}, {"0iter", "0"}]
      assert categories("10iter") == [:iterations_lit]
    end

    test "fractional counts are rejected" do
      assert error("2.5iter").message =~ "an iteration count must be a whole number, got 2.5iter"
      assert error("2.5iter/vu").message =~ "an iteration count must be a whole number, got 2.5iter/vu"
    end

    test "a count per user is one token with iter/vu (C175)" do
      assert values("1iter/vu 20iter/vu") == [{"1iter/vu", "1"}, {"20iter/vu", "20"}]
      assert categories("1iter/vu") == [:iterations_lit]
      # with spaces it is a count, a division and a name
      assert categories("1iter / vu") == [:iterations_lit, :/, :identifier]
    end

    test "other suffixes are not units" do
      assert error("10iters").message =~ ~s("iters" is not a unit)
      assert error("10it").message =~ "iteration count: iter"
      # request counts were replaced by iteration counts; req is no longer a unit
      assert error("10req").message =~ ~s("req" is not a unit)
    end
  end

  describe "Percentages (C34, C35, C82)" do
    test "up to two decimals" do
      assert values("70% 33.3% 33.33%") == [{"70%", "70"}, {"33.3%", "33.3"}, {"33.33%", "33.33"}]
    end

    test "three decimals are rejected" do
      assert error("33.333%").message =~ "at most two decimal places"
    end

    test "a space before % is rejected" do
      assert error("70 %").message =~ "without a space"
    end
  end

  describe "numbers" do
    test "integers and decimals" do
      assert tokens("42 0.5") == [{:int_lit, {1, 1}, "42"}, {:float_lit, {1, 4}, "0.5"}]
    end

    test "a dot after an integer is member access" do
      assert categories("xs[1].a") == [:identifier, :"[", :int_lit, :"]", :., :identifier]
    end
  end

  describe "strings (C64, C65)" do
    test "escapes are resolved" do
      assert values(~S("a\"b\\c\nd\te")) == ["a\"b\\c\nd\te"]
    end

    test "empty string" do
      assert tokens(~s("")) == [{:string_lit, {1, 1}, ""}]
    end

    test "raw strings keep their content exactly and may span lines" do
      assert tokens(~s("""{"id": 42}\n\\n""")) == [{:raw_string_lit, {1, 1}, ~s({"id": 42}\n\\n)}]
    end

    test "raw string ending in a quote" do
      assert values(~s("""say "hi"""")) == [~s(say "hi")]
    end

    test "invalid escape" do
      assert error(~S("a\qb")).message =~ ~S(invalid escape sequence \q)
    end

    test "unterminated strings" do
      assert error(~s("abc\n")).message =~ "unterminated string"
      assert error(~s("""abc)).message =~ "unterminated raw string"
    end
  end

  describe "comments" do
    test "line and block comments are skipped" do
      assert categories("a // x\n/* y\n z */ b") == [:identifier, :identifier]
    end

    test "unterminated block comment" do
      e = error("a /* never closed")
      assert {e.line, e.column} == {1, 3}
      assert e.message =~ "unterminated block comment"
    end
  end

  describe "identifiers and keywords (C8, C77)" do
    test "reserved words get their own token" do
      assert categories("let mut fn TestSuite Config latency asserts check checks map foldr null http") ==
               [
                 :let,
                 :mut,
                 :fn,
                 :TestSuite,
                 :Config,
                 :latency,
                 :asserts,
                 :check,
                 :checks,
                 :map,
                 :foldr,
                 :null,
                 :http
               ]
    end

    test "contextual keywords get their own token (the parser accepts them as names)" do
      assert categories(
               "warmup requestTimeout stopIf now p95 timeouts connectionErrors assertFailures failed"
             ) ==
               [
                 :warmup,
                 :requestTimeout,
                 :stopIf,
                 :now,
                 :p95,
                 :timeouts,
                 :connectionErrors,
                 :assertFailures,
                 :failed
               ]

      assert categories("linear exponential sut baseUrl output requests summary file fields includeWarmup") ==
               [
                 :linear,
                 :exponential,
                 :sut,
                 :baseUrl,
                 :output,
                 :requests,
                 :summary,
                 :file,
                 :fields,
                 :includeWarmup
               ]
    end

    test "ordinary identifiers, including unit-like words" do
      assert values("euCentral x_1 ms vu J") == ["euCentral", "x_1", "ms", "vu", "J"]
    end

    test "underscore is a token; identifiers cannot start with one" do
      assert categories("_") == [:_]
      assert error("_x").message =~ "must start with a letter"
    end
  end

  describe "operators" do
    test "multi-character operators" do
      assert categories(~S(|| && >= <= == != => -> > < = \ ^)) ==
               [:||, :&&, :>=, :<=, :==, :!=, :"=>", :->, :>, :<, :=, :"\\", :^]
    end

    test "host is a contextual keyword (C156)" do
      assert categories("host") == [:host]
    end

    test "the monitoring settings are contextual keywords (C158, C159, C161)" do
      assert categories("metrics metricsPort monitoring interval port path format carbonIntensity") ==
               [:metrics, :metricsPort, :monitoring, :interval, :port, :path, :format, :carbonIntensity]
    end

    test "the mqtt settings are contextual keywords (C163)" do
      assert categories("topics mqtt broker qos samples") == [:topics, :mqtt, :broker, :qos, :samples]
    end

    test "a carbon intensity is one token, a carbon value divided stays three (C161)" do
      assert categories("380gCO2e/kWh") == [:carbon_intensity_lit]
      assert categories("0.5gCO2e/kWh") == [:carbon_intensity_lit]
      assert categories("380gCO2e / kWh") == [:carbon_lit, :/, :identifier]
    end

    test "! is its own token, != stays one token (C147)" do
      assert categories("! != !a") == [:!, :!=, :!, :identifier]
    end

    test "illegal characters" do
      e = error("a ' b")
      assert {e.line, e.column} == {1, 3}
      assert e.message =~ "strings use double quotes"
    end
  end
end
