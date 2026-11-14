# aetherion

A [poncho project](https://embedded-elixir.com/post/2017-05-19-poncho-projects/): two Mix projects side by side,
joined by a path dependency instead of an umbrella. Each has its own `mix.exs`, `deps` and `_build`.

```
perflang/    the PerfLang language: lexer, parser, validator, analyzer, the typed AST, the EBNF and examples
aetherion/   the execution engine of PerfLang, and the command line (mix perflang run, bin/perflang)
```

`aetherion` depends on `perflang` (`{:perflang, path: "../perflang"}`); `perflang` depends on nothing.

```sh
cd perflang  && mix test                 # the language
cd aetherion && mix deps.get && mix test # the engine, compiles perflang as a dependency

aetherion/bin/perflang run perflang/examples/t1-basic-http-get-req.perf --seed 42
```

Requires Elixir 1.18 or later. See [perflang/README.md](perflang/README.md) and
[aetherion/README.md](aetherion/README.md).
