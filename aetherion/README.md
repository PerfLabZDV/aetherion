# Aetherion

Aetherion is the execution engine of [PerfLang](../perflang/README.md): it runs a suite that `PerfLang.analyze/2` has
accepted, Test by Test through its phases, and writes the results. It uses Mint for HTTP and emqtt for MQTT, and
depends on `perflang` (`{:perflang, path: "../perflang"}`) for the typed AST. It also holds the command line,
`mix perflang run` and `bin/perflang`, since that needs both the language and the engine.

```
lib/aetherion.ex               runs a suite: Tests in order, each through its phases
lib/aetherion/interpreter.ex   runs the statements of a phase over the typed AST
lib/aetherion/load.ex          virtual users, stages and iterations
lib/aetherion/http.ex          HTTP requests (Mint), one connection per user
lib/aetherion/monitor.ex       machine metrics: agents, MQTT plugs, the load generator
lib/aetherion/recorder.ex      what a Test records, and the metrics read from it
lib/aetherion/stats.ex         statistics across runs
lib/aetherion/report.ex        requests and samples files, summary, console report
lib/aetherion/signals.ex       a clean stop on SIGTERM
lib/aetherion/cells.ex         `let mut` lists, the only values `add` changes
lib/aetherion/values.ex        run-time values and their operators
lib/aetherion/source.ex        source text of an AST node, for messages
lib/aetherion/cli.ex           the command line, and its exit codes
lib/mix/tasks/perflang.ex      mix perflang run
bin/perflang                   the same command, and a clean stop on Ctrl+C
test/                          engine tests, with a local HTTP server and MQTT broker (server_helper.exs)
```

```elixir
{:ok, ast} = PerfLang.parse_file("shop.perf")
{:ok, ast} = PerfLang.validate(ast)
{:ok, ast} = PerfLang.analyze(ast)
%{exit_code: 0} = Aetherion.run(ast, seed: 42)
```

The language itself, from configuration and iterations to runs and pass criteria, is described in
[../perflang/README.md](../perflang/README.md).

## Running a test

Requires Elixir 1.18 or later, for its JSON module.

```sh
mix deps.get
mix perflang run ../perflang/examples/t6-multi-step-user-journey.perf --config ../perflang/examples/staging.perfcfg --seed 42
bin/perflang run ../tests/shop.perf --config staging.perfcfg --runs 10
```

The process exits with 0 when every Test passed, 1 when a Test failed and 2 when the run could not start or finish
(C132). `--config`, `--seed` and `--runs` are optional (C165, C178).

`bin/perflang` is the same command, from any directory, with paths relative to that directory. Use it to stop a run by
hand: on Ctrl+C or SIGTERM the users finish their requests, Verify is skipped, Cleanup runs, and the run exits with 2
(C155). The Erlang VM cannot catch SIGINT, so Ctrl+C under plain `mix perflang run` opens the VM's break menu and skips
Cleanup; SIGTERM works under both.

A virtual user is one process with its own connection. On one machine, against a local Elixir server, the engine
reached about 20,000 requests a second with 2000 users. Watch `loadGenerator.cpu`: a busy generator measures itself.

## Summary file

The summary is one JSON object (C121). `version` changes with the layout; this is version 3, the same for one run or
several (C180). Times are in milliseconds, percentages are numbers from 0 to 100, energy is in joules, power in watts
and carbon in grams of CO2e. `runs` holds every run with its Tests, and `tests` each Test across the counted runs.

```json
{
  "version": 3,
  "suite": "ShopCheckout",
  "seed": 42,
  "startedAt": "2026-10-31T10:00:00Z",
  "durationMs": 3630000,
  "result": "passed",
  "experiment": { "count": 11, "discard": 1, "cooldownMs": 30000 },
  "runs": [
    {
      "run": 1, "seed": 42, "discarded": true, "startedAt": "2026-10-31T10:00:00Z", "durationMs": 300000,
      "result": "passed", "tests": [ ... ]
    },
    {
      "run": 2, "seed": 2060880739, "discarded": false, "startedAt": "2026-10-31T10:05:30Z", "durationMs": 300000,
      "result": "passed", "tests": [ ... ]
    }
  ],
  "tests": [
    {
      "name": "UserJourney",
      "result": "passed",
      "runs": { "counted": 10, "passed": 10, "failed": 0 },
      "aggregate": {
        "metrics": {
          "requests": {
            "n": 10, "mean": 26410.2, "sd": 61.3, "cv": 0.23, "median": 26405, "min": 26320, "max": 26502,
            "ci95": { "low": 26366.3, "high": 26454.1 }
          },
          "latency": {
            "p95": {
              "n": 10, "mean": 121.4, "sd": 4.1, "cv": 3.38, "median": 120.9, "min": 115.2, "max": 129.0,
              "ci95": { "low": 118.47, "high": 124.33 }
            }
          }
        },
        "endpoints": [ { "target": "shop", "method": "GET", "url": "/api/products", "requests": { "n": 10 } } ],
        "targets": [ { "name": "euCentralApp", "readings": { "cpu": { "mean": { "n": 10 } } } } ],
        "loadGenerator": { "cpu": { "mean": { "n": 10 } } }
      }
    }
  ]
}
```

`aggregate` has the layout of a Test in one run, with a description in place of every number; text and sample counts
are left out. A value missing in some runs is described over the runs that have it, and `n` says how many. Without a
spread, `sd`, `cv` and `ci95` are null, and `cv` is null when the mean is 0.

A Test in one run has this layout. `targets` lists every measured target and every target with a `baseUrl`; `metrics`
holds the request metrics of a target that takes requests (C176), with `requests` 0 and no values when it got none, and
is null for a machine that only is measured.

```json
{
  "name": "UserJourney",
  "result": "passed",
  "stoppedBy": null,
  "metrics": {
    "requests": 26400,
    "latency": { "p50": 41, "p90": 88, "p95": 120, "p99": 240, "mean": 52, "min": 9, "max": 871 },
    "throughput": { "perSecond": 88.0 },
    "errors": {
      "rate": 0.4, "count": 106, "timeouts": 3, "connectionErrors": 0, "assertFailures": 103, "checkFailures": 0
    },
    "energy": { "total": 18000, "perRequest": 0.68, "perUser": 600 },
    "power": { "mean": 60.0, "peak": 92.0 },
    "carbon": { "total": 1.9, "perRequest": 0.00007 },
    "asserts": { "failed": 103, "rate": 0.4 },
    "checks": { "failed": 0, "rate": 0 }
  },
  "endpoints": [
    {
      "target": "shop",
      "method": "GET",
      "url": "/api/products",
      "requests": 8800,
      "latency": { "p50": 38, "p90": 80, "p95": 110, "p99": 200, "mean": 47, "min": 9, "max": 640 },
      "throughput": { "perSecond": 29.3 },
      "errors": {
        "rate": 0.2, "count": 18, "timeouts": 1, "connectionErrors": 0, "assertFailures": 17, "checkFailures": 0
      }
    }
  ],
  "targets": [
    {
      "name": "euCentralApp",
      "energy": { "total": 18000, "source": "mqtt", "samples": 30 },
      "readings": { "cpu": { "mean": 41.2, "max": 88.0, "samples": 300 } },
      "metrics": null
    },
    {
      "name": "shop",
      "energy": null,
      "readings": {},
      "metrics": {
        "requests": 26400,
        "latency": { "p50": 41, "p90": 88, "p95": 120, "p99": 240, "mean": 52, "min": 9, "max": 871 },
        "throughput": { "perSecond": 88.0 },
        "errors": {
          "rate": 0.4, "count": 106, "timeouts": 3, "connectionErrors": 0, "assertFailures": 103, "checkFailures": 0
        }
      }
    }
  ],
  "loadGenerator": { "cpu": { "mean": 12.0, "max": 33.1 }, "mem": { "mean": 18.0, "max": 19.4 } },
  "verify": [
    {
      "kind": "assert",
      "source": "errors.rate() < 2%",
      "line": 80,
      "column": 7,
      "values": { "errors.rate()": 0.4 },
      "passed": true
    }
  ],
  "failures": [
    { "kind": "assert", "phase": "Actions", "line": 53, "column": 7, "count": 103 }
  ]
}
```

