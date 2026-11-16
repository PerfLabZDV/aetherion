# Aetherion

Aetherion runs performance tests written in PerfLang. This project holds the language, built from `perflang.ebnf`
(version 1.37, decisions C1 to C186) with Erlang's built-in generators **leex** for the lexer and **yecc** (LALR(1))
for the parser, and its execution engine, which uses Mint for HTTP and emqtt for MQTT. The language lives in the
`PerfLang` modules and the engine in the `Aetherion` modules.

## Quick start

On a main server deployed with the Debian package and Ansible (see [Deployment on Debian 13](#deployment-on-debian-13)),
load the shared cookie from `/etc/aetherion/main.env` into the shell, then run a suite:

```sh
set -a; . /etc/aetherion/main.env; set +a
aetherion run examples/mixed-workload.perf
```

Without the cookie, the run stops with `workers need a shared cookie: set AETHERION_COOKIE, or pass --cookie`. The
file is readable by root and the group `aetherion`; a user added to the group must log in again first.

## Layout

```
perflang.ebnf                  the grammar and decisions C1 to C186
src/perflang_lexer.xrl         token rules (leex)
src/perflang_parser.yrl        grammar, one nonterminal per EBNF rule (yecc)
lib/perflang.ex                public API of the language
lib/perflang/lexer.ex          runs leex, adds line/column, builds literal values, lexical errors
lib/perflang/parser.ex         runs yecc, readable syntax errors
lib/perflang/ast.ex            AST structs
lib/perflang/validator.ex      structural checks the grammar defers, all errors at once
lib/perflang/analyzer.ex       names, types and units, all errors at once, returns the typed AST
lib/perflang/error.ex          PerfLang.Error (stage, message, line, column, file)
lib/aetherion.ex               runs a suite: Tests in order, each through its phases
lib/aetherion/interpreter.ex   runs the statements of a phase over the typed AST
lib/aetherion/load.ex          virtual users, stages and iterations
lib/aetherion/http.ex          HTTP requests (Mint), one connection per user
lib/aetherion/monitor.ex       machine metrics: agents, MQTT plugs, the load generator
lib/aetherion/machine.ex       cpu, mem, disk and net of this machine from /proc, for the aetherion agent
lib/aetherion/agent.ex         the monitoring agent of a machine under test, and its sessions
lib/aetherion/recorder.ex      what a Test records, and the metrics read from it
lib/aetherion/stats.ex         statistics across runs
lib/aetherion/report.ex        requests and samples files, summary, console report
lib/aetherion/requests_file.ex the requests file, written during each Test
lib/aetherion/signals.ex       a clean stop on SIGTERM
lib/aetherion/cells.ex         `let mut` lists, the only values `add` changes
lib/aetherion/values.ex        run-time values and their operators
lib/aetherion/source.ex        source text of an AST node, for messages
lib/aetherion/cluster.ex       the main server's side of a run on workers
lib/aetherion/worker.ex        a worker, and its sessions of virtual users
lib/aetherion/cli.ex           the command line, and its exit codes
lib/aetherion/release.ex       the command line of the release, for the Debian package
lib/mix/tasks/aetherion.ex     mix aetherion run
bin/aetherion                  the same command, and a clean stop on Ctrl+C
rel/vm.args.eex                flags of the Erlang VM of the release
packaging/debian/              the Debian 13 package: build.sh, and the files it installs
packaging/ansible/             deploy.yml, which installs the package on main servers, workers and agents
test/                          533 tests; fixtures/full_suite.perf holds every example from the EBNF,
                               server_helper.exs a local HTTP server and MQTT broker for the engine tests, and
                               cluster_test.exs runs suites on worker and agent nodes on this machine
examples/                      example suites, e.g. t1-basic-http-get-req.perf, and staging.perfcfg, an external
                               configuration file
```

## Module pipeline

```
source text
  -> PerfLang.Lexer       tokens with line and column
  -> PerfLang.Parser      AST (PerfLang.AST)
  -> PerfLang.Validator   the same AST, checked
  -> PerfLang.Analyzer    the same AST, every expression typed
  -> Aetherion            runs the Tests, and writes the results
```

`PerfLang.parse/1` runs the lexer and the parser, and stops at the first error. `PerfLang.validate/1` and
`PerfLang.analyze/2` are separate steps and report every error they find. `Aetherion.run/2` takes the result.

## Running a test

Requires Elixir 1.18 or later, for its JSON module.

```sh
mix deps.get
mix aetherion run examples/t6-multi-step-user-journey.perf --config examples/staging.perfcfg --seed 42
bin/aetherion run ../tests/shop.perf --config staging.perfcfg --runs 10
```

The process exits with 0 when every Test passed, 1 when a Test failed and 2 when the run could not start or finish
(C132). `--config`, `--seed` and `--runs` are optional (C165, C178).

While it runs, the console shows when the suite and each Test start and end, and with several runs each run, in UTC
like the requests and samples files. The report follows at the end, closed by the start and end of the whole run:

```
2026-11-16T10:00:00Z  Suite MixedWorkload started (seed 42)
2026-11-16T10:00:00Z  Test MixedWorkload started
2026-11-16T10:05:31Z  Test MixedWorkload ended after 5m31s: passed

Test MixedWorkload: PASSED
  ...

Seed 42, passed
Started 2026-11-16T10:00:00Z, ended 2026-11-16T10:05:31Z, after 5m31s
```

`bin/aetherion` is the same command, from any directory, with paths relative to that directory. Use it to stop a run by
hand: on Ctrl+C or SIGTERM the users finish their requests, Verify is skipped, Cleanup runs, and the run exits with 2
(C155). The Erlang VM cannot catch SIGINT, so Ctrl+C under plain `mix aetherion run` opens the VM's break menu and skips
Cleanup; SIGTERM works under both.

A virtual user is one process with its own connection. On one machine, against a local Elixir server, the engine
reached about 20,000 requests a second with 2000 users. Watch `loadGenerator.cpu`: a busy generator measures itself.

## Workers

One machine can be the limit: its CPU, its connections, or where the load comes from. With workers, a main server
runs the suite and other servers run the virtual users. The main server runs the stages, Setup, Verify, Cleanup,
stopIf, the monitoring of the system under test and the report, and splits each user count across the workers.
The workers only run Actions (C182).

Workers are a section of the Config, in the suite or in the external configuration file, like `sut` (C181). The name
and the host make the node name of a worker, `euWorker1@10.0.0.11`:

```
Config {
  workers {
    euWorker1 { host = "10.0.0.11"; }
    euWorker2 { host = "10.0.0.12"; }
    usWorker  { host = "10.1.0.11"; }
  }
}
```

```sh
# on every worker, left running; the same version of Aetherion on every server
export AETHERION_COOKIE=...   # a long random secret, the same on every server
bin/aetherion worker --name euWorker1@10.0.0.11

# on the main server
export AETHERION_COOKIE=...
bin/aetherion run shop.perf --config staging.perfcfg
bin/aetherion run shop.perf --workers euWorker1@10.0.0.11,euWorker2@10.0.0.12   # replaces the section (C184)
```

With workers, the load generators are the workers, not the main server (C183). `loadGenerator.cpu.max()` reads the
samples of every worker, as `sut.cpu` reads every target, and `loadGenerator.euWorker1.cpu.max()` one worker. Each
worker samples `cpu` and `mem` at the monitoring interval while it runs users. The report and the summary show all
workers together and each one.

```
Verify {
  assert loadGenerator.cpu.max() < 70%;            // every worker
  assert loadGenerator.usWorker.mem.max() < 80%;   // one worker
}
```

With `stages [ 2000vu for 5m ]` and three workers, each runs 667 users, the first one more. Users are numbered
across the workers, so `virtualUser` in the requests file stays unique. The workers send the requests that count, and
their request attempts for the requests file, every 50ms, so stopIf and the console report see all of them, percentiles
stay exact (C172), and the main server writes the file during the run. When the stages end, each worker stops its users,
waits for their last requests and sends the rest; Verify starts after that.

A stage with a count splits its iterations once, when it opens, in proportion to the users: `5vu for 41iter` on two
workers is 3 users with 25 iterations and 2 users with 16 (C103). The stage ends when every worker has finished its
part, so a slow worker cannot hand iterations to a fast one, as a slow user can on one machine. With `iter/vu` each
user runs its own count wherever it runs (C175). During a ramp by iterations, users go first to the workers that
still have iterations to finish.

Each worker measures on the main server's clock: when a Test starts, the main server measures how far each worker's
clock is from its own, so warmup ends at the same moment everywhere, the requests file is in time order across
workers to within about a millisecond, and Verify reads an Actions variable from the iteration that set it last, on any
worker (C136).

The nodes talk over Erlang distribution: port 4369 (epmd) and one port per node, which can be fixed for a firewall
with `ELIXIR_ERL_OPTIONS="-kernel inet_dist_listen_min 4370 inet_dist_listen_max 4370"`. The cookie is the only check
and nothing is encrypted, so keep the nodes on a private network or a VPN such as WireGuard. `--name main@10.0.0.10`
names the main server's node; by default it is named after the address that reaches the first worker. `--cookie` works
too, but shows in the process list.

A worker that goes away ends the run with exit code 2, as a run that cannot finish (C132), and the other workers stop
their users. Ctrl+C on the main server stops the users on every worker, and Cleanup runs (C155). Workers stay up for
the next run.

Not across workers: an `add` from Actions to a list of Setup (C137) reaches Verify and Cleanup, but not the users of
other workers during the run.

## Monitoring agents

A machine under test can be measured by Aetherion itself instead of node_exporter (C185). The same release runs there
as `aetherion agent`, which only measures: `cpu`, `mem`, `disk` and `net` of its machine. Name the agent after its
target, with the target's host:

```sh
# on every machine under test, left running; the same version and cookie as the main server
export AETHERION_COOKIE=...
bin/aetherion agent --name sutServer1@192.168.178.91
```

```
Config {
  sut {
    socialNetwork { baseUrl = "http://192.168.178.91:8080"; }
    sutServer1 {
      host    = "192.168.178.91";
      metrics = [cpu, mem, disk, net, power];
      topics  { power = "tele/tasmota_64E19E/SENSOR"; }   // power still comes from the plug
    }
  }
  monitoring {
    interval = 1s;
    format   = aetherion;
    mqtt { broker = "mqtt://localhost:1883"; fields { power = "ENERGY.Power"; } }
  }
}
```

`format = aetherion` makes every target with metrics from an agent the node `<target>@<host>`, with the host of
`baseUrl` when the target has no `host`. There is no `port`, `path`, `fields` or `metricsPort` for it, and `gpu`, or
`power` without a topic, is rejected, since the agent does not measure them. The readings are the ones the engine
computes from node_exporter, so a target reads the same with either agent: `cpu` from the per-mode counters of
`/proc/stat` (C174), `mem` from `MemAvailable`, `disk` as the share of time spent on I/O of the whole disks, and
`net` as received plus sent bytes per second (C186). Selectors work as with node_exporter: `cpu[0, 1]`,
`disk["nvme0n1"]`, `net["eth0"]`.

The agent samples at the monitoring interval on its own clock and keeps the samples until the main server takes them,
at least every 250ms; the main server moves each sample to its own clock, as for workers. A late take loses nothing
and does not move a sample in time.

`aetherion run` connects to every agent before the first Test, like the workers, and checks that each runs the same
code; an agent that cannot be reached is an error with exit code 2 (C132). A lost agent, or one that does not answer
for 5 seconds, is reached again at once and then every second until the Test ends; the samples in between are lost,
and the gap shows in the samples file. A machine can run a worker and an agent: they are two nodes, with two names and
two ports, `4370` for the worker and `4371` for the agent in the Debian package.

## Deployment on Debian 13

`packaging/debian/build.sh` builds a Debian 13 package, `packaging/debian/dist/aetherion_0.1.0-1_amd64.deb`, in a Debian
13 container, so it needs only Docker. The package holds a release with its own Erlang runtime, so the servers need no
Erlang, Elixir or build tools. The same package goes on the main server, on every worker and on every machine under
test with an agent:

```sh
packaging/debian/build.sh                # RUN_TESTS=1 runs the tests first, on Debian's Elixir 1.18

sudo apt install ./aetherion_0.1.0-1_amd64.deb
aetherion run shop.perf --config staging.perfcfg      # the same command line as bin/aetherion
```

On a worker, `/etc/aetherion/worker.env` holds its node name, the cookie and its distribution port, 4370, and the
`aetherion-worker` service runs it as the system user `aetherion`:

```sh
sudoedit /etc/aetherion/worker.env       # AETHERION_NAME=euWorker1@10.0.0.11, AETHERION_COOKIE=...
sudo systemctl enable --now aetherion-worker
```

On a machine under test, `/etc/aetherion/agent.env` does the same for the `aetherion-agent` service, on port 4371
(C185):

```sh
sudoedit /etc/aetherion/agent.env        # AETHERION_NAME=sutServer1@192.168.178.91, AETHERION_COOKIE=...
sudo systemctl enable --now aetherion-agent
```

A worker accepts the main server on ports 4369 and 4370, an agent on 4369 and 4371; the main server needs no open
port. Installing the package
again restarts a running worker, and every server must run the same version. The package's guide,
`/usr/share/doc/aetherion/README.Debian` (`packaging/debian/files/README.Debian`), has the details.

For many servers, `packaging/ansible/deploy.yml` installs the package on the main servers, workers and agents of an
inventory, writes each worker's `worker.env` and each agent's `agent.env` with a cookie from a vault, starts them and
checks that the main servers reach them (`packaging/ansible/README.md`):

```sh
cd packaging/ansible
ansible-playbook deploy.yml --ask-vault-pass
```

`packaging/build-and-deploy.sh` builds the package and runs the playbook in one step, and passes its arguments on to
`ansible-playbook`. It asks for the vault password itself when the cookie is in a vault. When sudo on the servers asks
for a password, add `--ask-become-pass`:

```sh
packaging/build-and-deploy.sh --ask-become-pass
SKIP_BUILD=1 packaging/build-and-deploy.sh --ask-become-pass   # deploy the package that is built already
```

## Usage

```sh
mix test
mix run -e 'IO.inspect(PerfLang.parse_file("test/fixtures/full_suite.perf"))'
```

```elixir
{:ok, %PerfLang.AST.TestSuite{} = ast} = PerfLang.parse(source)
{:ok, tokens} = PerfLang.tokenize(source)

{:error, %PerfLang.Error{line: 2, column: 17, message: "unexpected number 2"}} =
  PerfLang.parse("TestSuite S {\n  Load { warmup 2; }\n}")
```

```elixir
{:ok, ast} = PerfLang.validate(ast)

{:error, [%PerfLang.Error{stage: :validator} | _] = errors} = PerfLang.validate(bad_ast)
Enum.map(errors, &PerfLang.Error.format/1)
# ["5:5: distribution adds up to 99.99%, must be exactly 100% (C36)", ...]
```

```elixir
{:ok, config} = PerfLang.parse_config_file("examples/staging.perfcfg")
{:ok, config} = PerfLang.validate(config)
{:ok, typed_ast} = PerfLang.analyze(ast, config: config)

{:error, [%PerfLang.Error{stage: :semantic} | _] = errors} = PerfLang.analyze(bad_ast)
Enum.map(errors, &PerfLang.Error.format/1)
# ["12:7: unknown target euCentrl; define it in Config or the external configuration (C143)", ...]
```

```elixir
%{exit_code: 0} = Aetherion.run(typed_ast, seed: 42)
```

## External configuration

Targets can live outside the suite, so one test runs against several environments unchanged (C157). An external
configuration file holds one `Config` block, in the same syntax as in a suite, and only its `sut`, `monitoring` and
`workers` (C181) sections. Its name is free; `.perfcfg` is the convention.

```
Config {
  sut {
    euCentral    { baseUrl = "https://eu.api.examp.com"; }
    euCentralApp { host = "10.0.0.10"; metrics = [cpu, mem, disk, gpu, power]; }
    euCentralDb  { host = "10.0.0.20"; metrics = [mem, disk["nvme0n1"]]; }
  }

  monitoring {
    interval = 1s;
    port     = 9100;
    path     = "/metrics";
    format   = prometheus;
    carbonIntensity = 380gCO2e/kWh;
  }
}
```

Targets are flat (C156). A target with a `baseUrl` takes requests, and a target with `metrics` is a machine that is
measured (C159). A target may be both. Without a `host`, a machine is measured at the host of `baseUrl`, so behind a
load balancer the machines need targets of their own. `monitoring` says how (C158): `format` is `prometheus`,
`json` or `aetherion` (see [Monitoring agents](#monitoring-agents)), and `interval` and `path` default to `1s` and
`/metrics`. A machine with a second agent is a second target
with the same `host` and its own `metricsPort`.

With `prometheus` the engine computes `cpu`, `mem`, `disk` and `net` from node_exporter, and `fields` names a metric that is
already a percentage or, for `power`, in watts, such as `fields { gpu = "DCGM_FI_DEV_GPU_UTIL"; }`. With `json` every
agent metric needs a field, a dotted path.

A device that publishes its own values, such as a smart plug, is read over MQTT (C163). A metric with a topic comes
over MQTT and the others from the agent, so each metric has one source. A target with only such metrics needs no
`host`.

```
euCentralApp {
  host    = "10.0.0.10";
  metrics = [cpu, mem, power];
  topics  { power = "tele/eucentral-app-server/SENSOR"; }
}

monitoring {
  mqtt {
    broker = "mqtt://broker.examp.com:1883";
    qos    = 1;
    fields { power = "ENERGY.Power"; }
  }
}
```

`fields` maps a metric to a dotted path in a JSON message; without one the message is a plain number. Power arrives in
watts. A Tasmota plug publishes every `TelePeriod` seconds, 300 by default and 10 at least, so set it low enough to
get several samples in a test.

A lost connection to the broker is opened again at once, then every second until the Test ends, and the topics are
subscribed again. A broker that stops answering is noticed within 15 seconds (keepalive 10s). The session is clean, so
messages published in between are lost, not delivered late with a wrong arrival time; energy integrates over the gap as
over any other time between samples. Only the first connection must succeed for the run to start.

A selector narrows a metric: `cpu[0, 1]` by logical core, `gpu[2]` by device id, `disk["nvme0n1"]` by device name,
`net["eth0"]` by interface. Readings then cover only those devices. Without a selector, `net` leaves out loopback and
the virtual interfaces of containers, bridges and tunnels (`veth*`, `docker*`, `br-*`, ...), which would count the
same bytes again (C186).

A suite can keep its own `Config`. A target defined in both places is replaced as a whole by the definition in the
file, and so is `monitoring`. `PerfLang.analyze/2` returns the AST with the merged `Config`, so the engine reads it
from one place.

### Machine metrics

Machine metrics are read like `cpu` (C109, C160), in Verify, `stopIf` and Cleanup (C146):

```
assert sut.euCentralDb.mem.max() < 80%;       // one target
assert sut.mem.mean() < 50%;                  // all targets that list it
assert sut.euCentralApp.power.mean() < 200W;  // power gives a Power
assert sut.euCentralApp.net.max() < 100MB/s;   // net gives a DataRate: B/s, kB/s, MB/s, GB/s (C186)
assert loadGenerator.cpu.max() < 70%;         // read locally, no agent; with workers, on the workers (C183)
```

`energy.total()` integrates the power samples of every target that lists `power`, and `carbon.total()` multiplies
that by `carbonIntensity` (C161). Sampling runs from Setup to Cleanup, but only samples in Actions outside warmup count
(C162). A value with no sample in that window is a failed assert with no value, and the report names the target (C164).
The report lists each target's energy with its source, `mqtt` or `agent`, because a plug measures the whole machine and
an agent often only part of it. `output { samples { file = "results/samples.jsonl"; } }` writes every sample (C173).

## Iterations

One iteration is one pass through Actions by one virtual user (C103). A stage can last a Time or a number of
iterations, counted in one of two ways:

```
stages [ 20vu for 20iter ]     // 20 in total, shared: a fast user may run more, a slow one none
stages [ 20vu for 1iter/vu ]   // 1 for each user, so 20 in total, one per user (C175)
```

`iter` is a total that all users claim from, like k6's shared-iterations; a ramp by iterations needs a total, since
its curve runs over it (C101). `iter/vu` gives every user in the stage exactly that many, like k6's
per-vu-iterations or JMeter's loop count, and only works in a `for` stage. Either way the stage ends when every
iteration has finished, and the next stage starts no earlier.

## Distribution

`sut.any` is a target picked by `distribution`, once per iteration, so a user stays on one target for a whole journey
(C168). Calls that name a target are not affected.

```
Load {
  stages [ 100vu for 5m ]
  distribution { euCentral 70%; usEast 30%; }
}

Actions {
  let products = sut.any.http.get("/api/products");
}
```

## Metrics per target

The request metrics `latency`, `throughput` and `errors` also work per target: they then read only the requests sent to
that target (C176). This makes a criterion per region possible, also through a `Target` value.

```
Verify {
  assert sut.europe.latency.p95() < 300ms;
  assert sut.europe.errors.rate() < 1%;

  for region in [sut.europe, sut.unitedStates] {
    assert region.errors.rate() < 1%;
  }
}
```

A target that got no counted request has no value, so its criterion fails instead of passing on no load. Like other
metrics they are read in Verify, Cleanup and fns, but not in `stopIf`, which reads live totals. `sut.latency.p95()` is
rejected: over all targets it is `latency.p95()`.

## Runs

A `runs` section runs the whole suite several times, for statistics across runs (C178):

```
Config {
  runs {
    count    = 11;    // runs of the whole suite, default 1
    cooldown = 30s;   // pause between two runs, default 0s; nothing is sampled in it
    discard  = 1;     // first runs left out of the statistics and the result, default 0
  }
}
```

```sh
bin/aetherion run shop.perf --runs 3   # replaces count, e.g. for a quick try
```

Each run is the whole suite, its Tests in order: run 1 (T1, T2), run 2 (T1, T2), so drift in the system under test
spreads over every Test. Runs are independent: each has its own users, connections, Setup and Cleanup, metrics and
sampling window, and Verify and `stopIf` work per run as before. `discard` warms the system under test itself (JIT,
caches, pools); `warmup` only skips the start of each run. A discarded run is run and reported, but counts in neither
the statistics nor the result.

Run 1 uses the seed itself and every other run a seed derived from it, so the runs make different random choices, one
`--seed` repeats the whole experiment, and one run repeats alone with its own seed: `--seed 2060880739 --runs 1`
(C179).

A Test passes when it passed in every counted run, and the exit code follows from that. A run that does not finish, or
Ctrl+C, also during a cooldown, ends the experiment: the finished runs are reported and written, and the run exits
with 2. The requests and samples files get the field `run`. The section belongs to the suite: an external
configuration file cannot hold it.

Every metric is computed per run, and the statistics describe those values over the counted runs (C180): n, mean,
standard deviation, coefficient of variation, median, min, max and the 95% confidence interval of the mean from
Student's t. Latencies are not pooled across runs, which would hide how much the runs differ. With one run there is no
spread, so standard deviation, coefficient of variation and interval have no value. The console shows each run, then
each Test across the counted runs:

```
Run 1 of 4 (seed 42, discarded): passed
  Test MixedWorkload: PASSED, 200 requests, 95.91/s, 0.00% errors, p95 42.23ms

Run 2 of 4 (seed 2060880739): passed
  Test MixedWorkload: PASSED, 200 requests, 98.28/s, 0.00% errors, p95 41.93ms
...

Test MixedWorkload: PASSED, passed in 3 of 3 counted runs
  mean ± 95% confidence interval (coefficient of variation)
  requests 200.00 ± 0.00 (n=3, CV 0.00%)
  throughput 97.58/s ± 2.69/s (n=3, CV 1.11%)
  errors 0.00% ± 0.00% (n=3)
  latency p95 42.04ms ± 0.46ms (n=3, CV 0.44%)
  POST socialNetwork/wrk2-api/post/compose p95 42.28ms ± 0.10ms (n=3, CV 0.09%)
  ...

Seed 42, 4 of 4 runs (1 discarded), passed
Started 2026-10-31T10:00:00Z, ended 2026-10-31T10:22:00Z, after 22m0s
```

Criteria on the statistics, such as a limit on the coefficient of variation, are not part of the language yet: Verify
reads one run.

## Text of a value

`+` joins two Strings only, so a number becomes text with `toString()` first (C177). It is a method, like `random()`.

```
let userIndex = range(0, 962).random();
let username  = "username_" + userIndex.toString();      // "username_17"
let path      = "/api/items/" + body["id"].toString();   // the same for 42 and "42"
```

| Value                       | Text                                                            |
|-----------------------------|-----------------------------------------------------------------|
| Int, Bool, String           | `42`, `true`, the String itself                                 |
| Float                       | shortest exact form, with a decimal point: `2.0`, `0.25`        |
| Time, Energy, Power, Carbon | base unit of the report: `1500ms`, `3600000J`, `2.5W`, `3gCO2e` |
| Percentage, VirtualUsers    | `70%`, `50vu`                                                   |
| Json string, number, Bool   | its content: `Lamp`, `42`, `true`                               |
| Json object or array        | compact JSON: `["a","b"]`                                       |
| Json null                   | a failed assert with no value                                   |

Unit values keep at most three decimals and drop `.0`. List, Response, Target, Fn and Unit have no text.

## Failures and pass criteria

Actions records failures and Verify decides the result of a Test (C117). Failures are expected under load, so with a
criterion in Verify one failed request does not fail a Test, but a failed criterion such as
`assert errors.rate() < 2%;` does.

```
Actions {
  let response = sut.shop.http.get("/api/products");
  assert response.status == 200;   // on failure the iteration ends and the user starts its next one
}

Verify {
  assert errors.rate() < 2%;       // this decides the result
}
```

| Statement                     | On failure, it stops                          | Fails the Test               |
|-------------------------------|-----------------------------------------------|------------------------------|
| `check`, in any phase         | nothing                                       | no                           |
| `assert` in Actions           | the iteration                                 | only without Verify criteria |
| `assert` in Setup             | Setup, Actions and Verify; Cleanup still runs | yes                          |
| `assert` in Verify or Cleanup | nothing                                       | yes                          |

A failed `assert` or `check` in Actions marks its request, so it counts in `errors.rate()` and `errors.count()` (C125,
C130).

A Test without criteria (no Verify, or a Verify that evaluates no assert) fails if any assert failed in Actions, so it
cannot pass by accident. Once Verify has a criterion, only Verify decides: a Test that adds
`assert latency.p95() < 300ms;` also needs `assert asserts.failed() == 0;` to keep failing on a failed assert.

## Requests file

The requests file (C120) is written during each Test, so a long run holds only a short window of request attempts in
memory, on one machine and with workers. Without a requests file no attempt is kept, and without `includeWarmup` no
warmup attempt (C122). Every 250ms the attempts that started more than a window ago are appended, in time order; the
rest when the Test ends. The window is the longest a request can take, `requestTimeout` times the attempts of `retry`
plus their delays, plus 2s, plus `thinkTime`: the last attempt of a request is final only at the user's next request or
the end of its iteration, since an assert can still mark it (C125). An attempt that becomes final later than that, after
a `sleep` in Actions, is written when it arrives, a little out of order. With the default `requestTimeout 30s` the
window is 32s, so memory holds about 32s of attempts; a shorter `requestTimeout` makes it smaller.

The metrics keep one compact row for every request that counts, for exact percentiles (C172), so a long run still grows
by those rows.

## Summary file

The summary is one JSON object (C121). `version` changes with the layout; this is version 4, the same for one run or
several (C180), which adds `workers` to each Test of version 3 (C183). Times are in milliseconds, percentages are
numbers from 0 to 100, energy is in joules, power in watts, carbon in grams of CO2e and `net` in bytes per second. `runs` holds every run with its
Tests, and `tests` each Test across the counted runs. `workers` is empty for a run on one machine.

```json
{
  "version": 4,
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
        "loadGenerator": { "cpu": { "mean": { "n": 10 } } },
        "workers": [ { "name": "euWorker1", "readings": { "cpu": { "mean": { "n": 10 } } } } ]
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
  "workers": [
    { "name": "euWorker1", "readings": { "cpu": { "mean": 12.0, "max": 33.1, "samples": 300 } } }
  ],
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


## How the EBNF maps onto leex and yecc

* **Rule for rule.** Each EBNF rule is a yecc nonterminal with the same name (`load statement` becomes
  `load_statement`). `{ x }` becomes a recursive list rule and `[ x ]` an extra production, since yecc is BNF.
* **No conflicts.** yecc builds the LALR(1) table with 0 shift/reduce and 0 reduce/reduce conflicts. A test
  (`test/parser_test.exs`, "yecc reports no conflicts") compiles the grammar with `warnings_as_errors`, so any
  future grammar change that introduces an ambiguity fails the build.
* **Literals with units are single tokens.** `7m30s`, `500ms`, `0.5kWh`, `2.5gCO2e`, `50vu`, `10iter`, `1iter/vu` and `33.33%` are
  matched by leex regular expressions, which also enforce "no space before the unit", "largest unit first, each
  at most once" (C29), "at most two decimals" (C35) and "whole virtual users" (C94). leex takes the longest
  match, so `5ms` is milliseconds, `5mJ` millijoules and `5mW` milliwatts, never `5m` followed by a letter (C41).
* **Reserved and contextual keywords (C77).** Reserved words get their own token and can never be names.
  Contextual keywords (Load, retry and Config settings, measurements, backoff strategies) also get their own token so
  the parser can match them where they have meaning, and the `ident` rule accepts them as ordinary names
  everywhere else. So `linear` works as a curve name and as a backoff strategy, and `min(a, b)` still works.
  One exception for reserved words: the metric group names and `http` may follow `.` as member names
  (`member_name`), so `response.latency` and `sut.euCentral.http` parse while `let latency = 1;` does not
  (C111, C112).
* **http is a built-in (C112-C115).** `http.get(...)` without a target parses as an `AST.Http` node, and
  `sut.euCentral.http.get(...)` as an ordinary member chain. The grammar treats both as calls; methods,
  arguments, urls and options are checked by the Validator.
* **Positions.** leex returns every token, whitespace and comments included, and `PerfLang.Lexer` computes
  exact `{line, column}` positions from them. This does not depend on the OTP version (column support in leex
  itself only arrived in newer OTP releases).

## Two places where the EBNF is ambiguous for LALR(1)

Both are resolved without changing what the EBNF accepts in practice, but they are worth confirming.

1. **`{` after `=>` in a match arm.** `200 => { }` could be an empty block or an empty JSON object. The EBNF
   comment already says "A `{` after `=>` always starts a block", so the arm body uses `expression_nb`, a copy of
   the expression rules whose leftmost value cannot be a JSON object. `200 => ({ "ok": true })` still gives JSON.

2. **A statement-level `match` followed by `(`, `[` or `-`.** In `match a { _ => g } (f)(1);` the `(f)` could
   either start the next statement or call the match result. The parser follows the Rust convention: a match at
   the start of a statement ends at its `}` (a `;` after it is accepted). Expression statements use
   `expression_nm`, a copy of the expression rules whose leftmost value cannot be a match. A match used inside a
   longer bare expression needs parentheses: `(match a { ... }).run();`. Anywhere else (in `let`, arguments,
   operands) a match works as a normal expression. Since a bare statement must be a call anyway (C63), this only
   affects statements that call a method on a match result directly.

## What the AST leaves for later passes

The parser accepts exactly the EBNF and leaves every "checked after parsing" rule to the next passes. The AST is
shaped for them:

* **Validator** (structural): settings and retry entries are kept in source order with duplicates (C61, C78,
  C85); `PercentageLiteral.hundredths` is exact (33.33% is 3333) for the 100% total (C36, C87);
  `TimeLiteral.parts` keeps every part with its unit, value and raw text for range and decimal checks (C31, C80,
  C81); `ExpressionStatement` marks bare expressions that must be calls (C63); `Return` placement (C74).
* **Semantic Analyzer** (names, types, units): `Var`, `Type` (with type arguments), `Lambda`, `ListOperation`,
  `Metric`, `Match` and the typed literals (`TimeLiteral`, `EnergyLiteral`, `PowerLiteral`, `CarbonLiteral`,
  `UsersLiteral`, `PercentageLiteral`). It fills the `type` field of every expression.
* **Execution engine** (`Aetherion`): waiting `thinkTime` after every response in Actions, never in Setup or Cleanup, with
  retries waiting by their `delay` instead (C16). Pausing a virtual user for `sleep(...)`, on top of thinkTime (C133).
  Picking random items for `.random()` and `.random(n)`, and on too few items a failed assert with no value, which
  also stops Verify and Cleanup (C134, C141). Running each Setup variable as one shared value and each `.add(x)`
  atomically (C137). Giving Verify and Cleanup each Actions variable from the last finished iteration that set it
  (C136). Converting Json at run time (C141). Counting only Actions requests in the metrics (C104) and writing the
  `phase` of each request (C120). Starting exactly the iterations a count stage asks for, and with `iter/vu` exactly that many for each user (C103,
  C175). Running Cleanup after
  failures, `stopIf` and interrupts (C155). Sampling the agents and the load generator, subscribing to MQTT topics, and
  integrating power into energy (C158-C164). Applying retries (C38, C86), `sut.any` (C168), the end of a stage (C169), one
  connection per user (C170), the limits on Setup and Cleanup (C171), and the seed (C165).
  What a failed `assert` does at run time (C116: Actions ends the iteration, Setup stops
  the Test, Verify and Cleanup go on), that a failed assert fails the Test in every phase but Actions, and there too when Verify has no criteria (C117), and recording failed asserts
  for `asserts.failed()` and `asserts.rate()` (C118). The grammar only adds the `asserts` metric group.
  A failed `check` (the soft assert) stops nothing and never fails the Test (C129); it is recorded for
  `checks.failed()` and `checks.rate()`, and in Actions marks its request as `checkFailed` (C130).
  Reporting every Verify assert and check with its measured values in the summary (C121) and on the console
  at the end of every run (C131), together with the request metrics per endpoint (C135) and the readings and energy of each measured target and the load generator's CPU and memory (C160, C161), and the exit code: 0 all Tests passed, 1 a Test failed, 2 the run could
  not start or finish (C132).
  Writing every request record and the summary to the files in `Config { output { ... } }` (C119-C122); where
  relative paths resolve and how a run overrides them is the engine's choice. Sending bodies by their type
  (C123): JSON values as `application/json`, strings as `text/plain; charset=utf-8`, `""` as no body, unless
  the headers option sets a Content-Type. Running the suite `count` times with a cooldown between runs, a seed per
  run, and statistics across the counted runs in the console report and the summary (C178-C180).

Every node has `loc: {line, column}` for error messages: the keyword for statements and blocks, the operator for
binary, member, call and index expressions, and the first token otherwise.

## Validator

`PerfLang.Validator.validate(ast)` runs after the parser and before the Semantic Analyzer. It returns
`{:ok, ast}` unchanged, or `{:error, errors}` with every error found (not just the first), sorted by position,
each a `PerfLang.Error` with stage `:validator`. There are only errors, no warnings. It checks:

* Config: each section (`sut`, `output`, `monitoring`, `runs`) at most once, each sut target once and none named `cpu`, `mem`,
  `disk`, `gpu` or `power` (`sut.cpu` means all targets, C109), each target setting at most once, and
  `baseUrl` an `http://` or `https://` URL with a host and no trailing `/` (C98, C99, C100), and `host` without
  scheme, path or spaces (C156). `metrics` known names, at least one, each once, with selectors that fit, on a target
  with a `host` or a `baseUrl`, and `metricsPort` only with `metrics` (C159). `monitoring` settings at most once and
  in range (C158, C161). `topics` for listed metrics, each once, without wildcards, and `mqtt` with an `mqtt://`
  `broker`, a `qos` of 0 to 2 and dotted `fields` (C163). `PerfLang.validate/1` also takes an external configuration file, which gets the same checks
  and holds only `sut` and `monitoring` (C157).
* runs: each setting at most once, `count` at least 1 and `discard` below `count` (C178).
* output: `requests` and `summary` at most once each, `summary` ends in `.json` (C119, C121). The `requests`
  block: each setting at most once, `file` required and ending in `.jsonl`, and `fields` known field names, at
  least one, each once; `warmup` is not a field, `includeWarmup = true;` adds it (C120, C122).
* Load placement, in the suite or in every Test (C10, C11). The grammar already enforces this; the check
  covers hand-built trees.
* Load settings at most once each except stopIf (C61, C78); retry entries at most once each (C85).
* `warmup` and `distribution` only with `stages`: a Load without stages runs one iteration with one virtual
  user, as `stages [ 1vu for 1iter ]` (C124).
* Iteration counts in stages greater than 0: `0iter` is rejected (C102). A count per user, `2iter/vu`, only in a
  `for` stage: `50vu in 2iter/vu` is rejected (C175).
* A `now` stage is not the last stage: the run ends there, so `stages [ 50vu for 1m, 0vu now ]` is rejected (C127).
* requestTimeout greater than 0, in any spelling (`0s`, `0ms`, `0m0s`) (C96).
* warmup shorter than the stages, when all their lengths are Times (C167).
* distribution: each target once, each value at most 100%, and a total of exactly 100.00% compared in
  hundredths, with no rounding slack (C36, C87).
* Time literals everywhere: parts after the first below 60 (minutes, seconds) or 1000 (milliseconds), and only
  the last part with decimals (C31, C80, C81).
* http calls (C112-C115, C123): methods get, head, delete, post, put, patch; get/head/delete take
  `(url [, options])` and post/put/patch `(url [, body [, options]])`; a standalone `http` needs a full http(s)
  URL and a target a path starting with `/` (when the url is a string literal); options is a JSON object with
  only `"headers"` and `"query"`, each once and each a JSON object (when written as literals); a body that is
  not a unit literal such as `5s` (C123); and `http` is only used as `http.<method>(...)`. Targets are not
  checked against Config (C45).
* sleep (C133): one argument, not negative, a Time when written as a literal, and no function named `sleep`.
* random (C134): `.random()` takes at most one argument, the count.
* A bare expression statement must be written as a call: `f(x)`, `a.b(x)`, `xs.map(f)` or a metric (C63).
* `return` only inside a function body (C74).
* Naming (C46): declared names (let, fn, parameters, curves and their parameters, for variables, lambda
  parameters, match bindings) are camelCase (`[a-z][A-Za-z0-9]*`); type names are PascalCase. Suite, Test
  and target names are not checked: C46 does not say how they are written, and targets also come from the
  external configuration (C33, C100).

Everything about names, types and units (unknown names, curve recursion, assignment to a non-mut variable,
Bool conditions, match coverage and arm types, targets) is left to the Semantic Analyzer.

## Semantic Analyzer

`PerfLang.analyze(ast, config: config)` runs after the Validator. `config` is the validated external configuration
file, and is optional. It returns `{:ok, ast}`, with the `type` of every expression set and the merged `Config`, or
`{:error, errors}` with every error found (not just the first), sorted by position, each a `PerfLang.Error` with stage
`:semantic`. There are only errors, no warnings. An expression that already failed gets an unknown type, so one
mistake gives one error rather than a chain of them. It checks:

* Scope (C136): Setup variables reach all later phases, and variables declared directly in Actions reach Verify and
  Cleanup. Block variables end with their block, and nothing crosses Tests.
* Shared state (C137): no assignment to a Setup variable from Actions, and `.add(x)` only on `let mut` lists.
* Types (C138-C140): only the built-in types, with `Int` widening to `Float`. A `[...]` literal is a `List<T>` or
  `Json` by context, and an empty `[]` takes its type from its annotation or first use.
* Json (C141): converts implicitly to `Int`, `Float`, `Bool`, `String` and lists; the value itself is checked at run
  time.
* Units (C142): arithmetic within one unit type, with numbers, and `Energy / Time` and `Power * Time`.
* Response members (C110): `status`, `outcome`, `latency`, `body` and `headers`.
* Targets (C143, C156, C158): every target is in Config or in the external file. Written as `sut.<target>`, http calls
  and `distribution` need a `baseUrl`. Metrics from an agent need a `format`, a port and any `fields` they need, and
  `topics` need `mqtt`. `sut.any` works in Actions, with a `distribution` (C168).
* Machine metrics (C160, C161, C183): a reading needs a target that lists the metric, and `loadGenerator` reads `cpu`
  and `mem`; `loadGenerator.euWorker1` needs a worker of that name. `energy`, `power` and `carbon` metrics need a
  target that lists `power`, and `carbon` needs `carbonIntensity`.
* Built-ins (C144, C145): `range`, the math built-ins in every expression, `.length()`, `.contains(x)` and `+` on
  strings.
* `toString()` (C177): no arguments, on a number, Bool, String, Json or unit value; List, Response, Target, Fn and
  Unit are rejected.
* Metrics (C146): read in Verify, `stopIf` and Cleanup, rejected in Setup and Actions.
* Metrics per target (C176): `sut.europe.latency.p95()` needs a target with a `baseUrl`, a measurement of C60 and
  no `stopIf`; `sut.latency.p95()` is rejected.
* Operators (C147, C153): `!` on Bool, unary `-` on numbers and units, `==` on values of one type, `<` on numbers and
  unit types.
* Match (C148): a value match gives one type and covers every case. A statement match needs neither.
* Names (C149): shadowing in inner scopes, no redeclaring in one scope, unique Test, fn and curve names, no
  overloading.
* Functions and lambdas (C150, C151): use before declaration, mutual recursion, a return on every path, and lambda
  types from context.
* stopIf and curves (C152): no http calls and no variables.
* `percentile(n)` (C154): n from 0 to 100.

Run-time rules stay with the engine: converting Json values (C141), an Actions variable no iteration set (C136),
`.random()` on too few items (C134), and an http call or a machine reading through a `Target` value on a target
without the setting it needs (C156, C160). The analyzer accepts them, since only the value can tell.
