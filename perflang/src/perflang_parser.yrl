%% PerfLang parser (yecc, LALR(1)), from perflang.ebnf version 1.1.
%%
%% Each EBNF rule maps to a nonterminal of the same name (spaces become
%% underscores). EBNF repetition { x } becomes a recursive list rule and
%% [ x ] becomes an extra production, since yecc is BNF. The grammar is
%% free of shift/reduce and reduce/reduce conflicts.
%%
%% Two places differ from a one-to-one transcription. Both are needed
%% because the EBNF is ambiguous there for an LALR(1) parser:
%%
%%  1. Match arm bodies (EBNF: "A { after => always starts a block").
%%     `=> { }` could be an empty block or an empty JSON object. The arm
%%     body uses `expression_nb`, a copy of the expression rules whose
%%     leftmost primary cannot be a JSON object, so `{` after `=>` is
%%     always a block, exactly as the EBNF comment says.
%%
%%  2. Match statements (EBNF: match statement = match expression; and
%%     expression statement = expression, ";"). After a statement-level
%%     `match x { ... }`, a following `(`, `[` or `-` could either start
%%     the next statement or continue the expression. The statement-level
%%     match always ends at its `}` (optionally followed by ";"), and an
%%     expression statement uses `expression_nm`, a copy of the
%%     expression rules whose leftmost primary cannot be a match. To use
%%     a match result inside a longer bare expression, wrap it in
%%     parentheses: (match x { ... }).foo();
%%
%% Nodes are built with n/3, which creates PerfLang.AST structs. Each
%% node's `loc` is the {Line, Column} of its defining token: the keyword
%% for statements and blocks, the operator for binary, unary, member,
%% call and index expressions, and the first token otherwise.

Nonterminals
perflang_file test_suite suite_body tests tests_with_load test test_with_load
test_phases load_block setup_block actions_block optional_verify verify_block cleanup_block
config_block config_sections config_section sut_section sut_targets sut_target
output_section output_settings output_setting
requests_block requests_settings requests_setting field_list field_name
target_settings target_setting base_url_setting host_setting
metrics_setting metrics_port_setting metric_sources metric_source metric_source_name devices device
monitoring_section monitoring_settings monitoring_setting carbon_intensity_literal
runs_section runs_settings runs_setting
topics_setting topic_entries topic_entry mqtt_block mqtt_settings mqtt_setting metric_fields metric_field
load_statements load_statement
warmup_setting curves_setting stages_setting think_time_setting
request_timeout_setting distribution_setting stop_if_setting retry_setting
curve_definitions curve_definition parameter_list
stage_list stage ramp_stage hold_stage now_stage stage_length curve
distribution_entries distribution_entry target_name
retry_entries retry_entry attempts_setting delay_setting backoff_setting
backoff_strategy
expression lambda lambda_parameters lambda_parameter_list lambda_parameter
list_operation fold_name function_value
or_expression and_expression comparison comparison_operator
sum product factor exponent postfix postfix_operation member_name argument_list primary
expression_nb or_expression_nb and_expression_nb comparison_nb sum_nb
product_nb factor_nb exponent_nb postfix_nb primary_nb
expression_nm or_expression_nm and_expression_nm comparison_nm sum_nm
product_nm factor_nm exponent_nm postfix_nm primary_nm
json_object json_members json_member json_array json_values json_value
metric latency_metric latency_measurement throughput_metric
errors_metric errors_measurement energy_metric energy_measurement
power_metric power_measurement carbon_metric carbon_measurement
asserts_metric asserts_measurement checks_metric checks_measurement
literal time_literal energy_literal power_literal carbon_literal
users_literal iterations_literal percentage_literal number_literal string_literal
quoted_string bool_literal integer
statements statement let_statement assignment_statement
expression_statement assert_statement check_statement type_name type type_list
block if_statement while_statement for_statement
match_expression match_arms match_arm match_arm_body pattern
match_statement return_statement
functions_block fn_declarations fn_declaration fn_parameter_list
fn_parameter
name ident.

Terminals
'TestSuite' 'Test' 'Load' 'Setup' 'Actions' 'Verify' 'Cleanup' 'Functions'
'Config' 'config_file' 'sut' 'baseUrl' 'host' 'samples' 'topics' 'mqtt' 'broker' 'qos' 'metrics' 'metricsPort' 'monitoring' 'interval' 'port' 'path' 'format' 'carbonIntensity' 'output' 'requests' 'summary' 'file' 'fields' 'includeWarmup' 'runs' 'cooldown' 'discard'
'let' 'mut' 'fn' 'if' 'else' 'while' 'for' 'in' 'match' 'return' 'assert' 'check'
'map' 'filter' 'fold' 'foldl' 'foldr' 'true' 'false' 'null'
'latency' 'throughput' 'errors' 'energy' 'power' 'carbon' 'asserts' 'checks' 'http'
'warmup' 'curves' 'stages' 'now' 'thinkTime' 'requestTimeout' 'distribution'
'retry' 'stopIf' 'attempts' 'delay' 'backoff' 'fixed' 'linear' 'exponential'
'p50' 'p90' 'p95' 'p99' 'mean' 'min' 'max' 'percentile' 'perSecond'
'rate' 'count' 'timeouts' 'connectionErrors' 'assertFailures' 'checkFailures' 'total' 'perRequest' 'perUser' 'peak' 'failed'
identifier time_lit energy_lit power_lit carbon_lit carbon_intensity_lit users_lit iterations_lit
percentage_lit int_lit float_lit string_lit raw_string_lit
'{' '}' '(' ')' '[' ']' ',' ';' ':' '.' '=' '=>' '->' '\\' '_'
'||' '&&' '>=' '<=' '>' '<' '==' '!=' '!' '+' '-' '*' '/' '^'.

Rootsymbol perflang_file.

%% ---------- Structure ----------

perflang_file -> test_suite : '$1'.

%% An external configuration file (C157). PerfLang.Parser adds config_file
%% in front of the tokens; the lexer never makes it.
perflang_file -> 'config_file' config_block : '$2'.

%% [ config block ], [ functions block ], suite body (C97)
test_suite -> 'TestSuite' name '{' suite_body '}' :
    suite('$1', '$2', nil, nil, '$4').
test_suite -> 'TestSuite' name '{' functions_block suite_body '}' :
    suite('$1', '$2', nil, '$4', '$5').
test_suite -> 'TestSuite' name '{' config_block suite_body '}' :
    suite('$1', '$2', '$4', nil, '$5').
test_suite -> 'TestSuite' name '{' config_block functions_block suite_body '}' :
    suite('$1', '$2', '$4', '$5', '$6').

%% Load at suite level, then Tests without Load; or no suite-level Load
%% and every Test defines its own (C10, C11).
suite_body -> load_block tests : {'$1', '$2'}.
suite_body -> tests_with_load  : {nil, '$1'}.

tests -> test       : ['$1'].
tests -> test tests : ['$1' | '$2'].

tests_with_load -> test_with_load                 : ['$1'].
tests_with_load -> test_with_load tests_with_load : ['$1' | '$2'].

test -> 'Test' name '{' test_phases '}' :
    test('$1', '$2', nil, '$4').

test_with_load -> 'Test' name '{' load_block test_phases '}' :
    test('$1', '$2', '$4', '$5').

%% [ setup block ], actions block, [ verify block ], [ cleanup block ]
test_phases -> actions_block optional_verify                           : {nil, '$1', '$2', nil}.
test_phases -> setup_block actions_block optional_verify               : {'$1', '$2', '$3', nil}.
test_phases -> actions_block optional_verify cleanup_block             : {nil, '$1', '$2', '$3'}.
test_phases -> setup_block actions_block optional_verify cleanup_block : {'$1', '$2', '$3', '$4'}.

optional_verify -> '$empty'     : nil.
optional_verify -> verify_block : '$1'.

load_block    -> 'Load' '{' load_statements '}' : n(load, '$1', [{settings, '$3'}]).
setup_block   -> 'Setup' '{' statements '}'     : phase(setup, '$1', '$3').
actions_block -> 'Actions' '{' statements '}'   : phase(actions, '$1', '$3').
verify_block  -> 'Verify' '{' statements '}'    : phase(verify, '$1', '$3').
cleanup_block -> 'Cleanup' '{' statements '}'   : phase(cleanup, '$1', '$3').

%% ---------- Config (C97-C100, C119-C121) ----------

config_block -> 'Config' '{' config_sections '}' :
    n(config, '$1', [{sections, '$3'}]).

config_sections -> '$empty'                       : [].
config_sections -> config_section config_sections : ['$1' | '$2'].

config_section -> sut_section    : '$1'.
config_section -> output_section : '$1'.
config_section -> monitoring_section : '$1'.
config_section -> runs_section : '$1'.

sut_section -> 'sut' '{' sut_targets '}' : n(sut, '$1', [{targets, '$3'}]).

sut_targets -> '$empty'               : [].
sut_targets -> sut_target sut_targets : ['$1' | '$2'].

sut_target -> target_name '{' target_settings '}' :
    n(sut_target, loc('$1'), [{name, val('$1')}, {settings, '$3'}]).

target_settings -> '$empty'                       : [].
target_settings -> target_setting target_settings : ['$1' | '$2'].

target_setting -> base_url_setting : '$1'.
target_setting -> host_setting     : '$1'.
target_setting -> metrics_setting  : '$1'.
target_setting -> metrics_port_setting : '$1'.
target_setting -> topics_setting   : '$1'.

base_url_setting -> 'baseUrl' '=' quoted_string ';' :
    n(base_url, '$1', [{value, lit(string, '$3')}]).

host_setting -> 'host' '=' quoted_string ';' :
    n(host, '$1', [{value, lit(string, '$3')}]).

%% metrics = [cpu[0, 1], mem, disk["nvme0n1"]]; (C159)
metrics_setting -> 'metrics' '=' '[' ']' ';' :
    n(target_metrics, '$1', [{metrics, []}]).
metrics_setting -> 'metrics' '=' '[' metric_sources ']' ';' :
    n(target_metrics, '$1', [{metrics, '$4'}]).
metrics_setting -> 'metrics' '=' '[' metric_sources ',' ']' ';' :
    n(target_metrics, '$1', [{metrics, '$4'}]).

metric_sources -> metric_source                    : ['$1'].
metric_sources -> metric_sources ',' metric_source : '$1' ++ ['$3'].

metric_source -> metric_source_name :
    n(metric_source, loc('$1'), [{name, val('$1')}, {devices, []}]).
metric_source -> metric_source_name '[' devices ']' :
    n(metric_source, loc('$1'), [{name, val('$1')}, {devices, '$3'}]).

%% Any name; the known metrics are checked after parsing (C159). power is
%% reserved (C77), so it is listed.
metric_source_name -> ident   : '$1'.
metric_source_name -> 'power' : '$1'.

%% topics { power = "tele/app/SENSOR"; } (C163)
topics_setting -> 'topics' '{' topic_entries '}' :
    n(target_topics, '$1', [{topics, '$3'}]).

topic_entries -> '$empty'                  : [].
topic_entries -> topic_entry topic_entries : ['$1' | '$2'].

topic_entry -> metric_source_name '=' quoted_string ';' :
    n(topic, loc('$1'), [{metric, val('$1')}, {value, lit(string, '$3')}]).

devices -> device             : ['$1'].
devices -> devices ',' device : '$1' ++ ['$3'].

device -> integer       : '$1'.
device -> quoted_string : lit(string, '$1').

metrics_port_setting -> 'metricsPort' '=' integer ';' :
    n(metrics_port, '$1', [{value, '$3'}]).

%% monitoring { interval = 1s; port = 9100; ... } (C158)
monitoring_section -> 'monitoring' '{' monitoring_settings '}' :
    n(monitoring, '$1', [{settings, '$3'}]).

monitoring_settings -> '$empty'                               : [].
monitoring_settings -> monitoring_setting monitoring_settings : ['$1' | '$2'].

monitoring_setting -> 'interval' '=' time_literal ';' :
    n(monitor_interval, '$1', [{value, '$3'}]).
monitoring_setting -> 'port' '=' integer ';' :
    n(monitor_port, '$1', [{value, '$3'}]).
monitoring_setting -> 'path' '=' quoted_string ';' :
    n(monitor_path, '$1', [{value, lit(string, '$3')}]).
monitoring_setting -> 'format' '=' ident ';' :
    n(monitor_format, '$1', [{value, val('$3')}]).
monitoring_setting -> 'carbonIntensity' '=' carbon_intensity_literal ';' :
    n(carbon_intensity, '$1', [{value, '$3'}]).
monitoring_setting -> mqtt_block : '$1'.
monitoring_setting -> 'fields' '{' metric_fields '}' :
    n(monitor_fields, '$1', [{fields, '$3'}]).

%% mqtt { broker = "mqtt://..."; qos = 1; fields { power = "ENERGY.Power"; } } (C163)
mqtt_block -> 'mqtt' '{' mqtt_settings '}' : n(mqtt, '$1', [{settings, '$3'}]).

mqtt_settings -> '$empty'                   : [].
mqtt_settings -> mqtt_setting mqtt_settings : ['$1' | '$2'].

mqtt_setting -> 'broker' '=' quoted_string ';' :
    n(mqtt_broker, '$1', [{value, lit(string, '$3')}]).
mqtt_setting -> 'qos' '=' integer ';' :
    n(mqtt_qos, '$1', [{value, '$3'}]).
mqtt_setting -> 'fields' '{' metric_fields '}' :
    n(mqtt_fields, '$1', [{fields, '$3'}]).

metric_fields -> '$empty'                    : [].
metric_fields -> metric_field metric_fields  : ['$1' | '$2'].

metric_field -> metric_source_name '=' quoted_string ';' :
    n(metric_field, loc('$1'), [{metric, val('$1')}, {path, lit(string, '$3')}]).

carbon_intensity_literal -> carbon_intensity_lit : lit(carbon_intensity, '$1').

output_section -> 'output' '{' output_settings '}' : n(output, '$1', [{settings, '$3'}]).

output_settings -> '$empty'                       : [].
output_settings -> output_setting output_settings : ['$1' | '$2'].

output_setting -> requests_block : '$1'.
output_setting -> 'samples' '{' 'file' '=' quoted_string ';' '}' :
    n(samples_output, '$1', [{value, lit(string, '$5')}]).
output_setting -> 'summary' '=' quoted_string ';' :
    n(summary_output, '$1', [{value, lit(string, '$3')}]).

%% runs { count = 10; cooldown = 30s; discard = 1; } (C178)
runs_section -> 'runs' '{' runs_settings '}' : n(runs, '$1', [{settings, '$3'}]).

runs_settings -> '$empty'                   : [].
runs_settings -> runs_setting runs_settings : ['$1' | '$2'].

runs_setting -> 'count' '=' integer ';' :
    n(runs_count, '$1', [{value, '$3'}]).
runs_setting -> 'cooldown' '=' time_literal ';' :
    n(runs_cooldown, '$1', [{value, '$3'}]).
runs_setting -> 'discard' '=' integer ';' :
    n(runs_discard, '$1', [{value, '$3'}]).

%% requests { file = "..."; fields = [...]; includeWarmup = true; } (C122)
requests_block -> 'requests' '{' requests_settings '}' :
    n(requests_output, '$1', [{settings, '$3'}]).

requests_settings -> '$empty'                           : [].
requests_settings -> requests_setting requests_settings : ['$1' | '$2'].

requests_setting -> 'file' '=' quoted_string ';' :
    n(output_file, '$1', [{value, lit(string, '$3')}]).
requests_setting -> 'fields' '=' '[' ']' ';' :
    n(output_fields, '$1', [{fields, []}]).
requests_setting -> 'fields' '=' '[' field_list ']' ';' :
    n(output_fields, '$1', [{fields, '$4'}]).
requests_setting -> 'fields' '=' '[' field_list ',' ']' ';' :
    n(output_fields, '$1', [{fields, '$4'}]).
requests_setting -> 'includeWarmup' '=' bool_literal ';' :
    n(include_warmup, '$1', [{value, '$3'}]).

field_list -> field_name                : ['$1'].
field_list -> field_list ',' field_name : '$1' ++ ['$3'].

%% Any name; the known fields are checked after parsing (C122). latency is
%% a reserved word, so it is listed on its own.
field_name -> ident     : n(field_name, loc('$1'), [{name, val('$1')}]).
field_name -> 'latency' : n(field_name, loc('$1'), [{name, val('$1')}]).

%% ---------- Load settings ----------

load_statements -> '$empty'                       : [].
load_statements -> load_statement load_statements : ['$1' | '$2'].

load_statement -> warmup_setting          : '$1'.
load_statement -> curves_setting          : '$1'.
load_statement -> stages_setting          : '$1'.
load_statement -> think_time_setting      : '$1'.
load_statement -> request_timeout_setting : '$1'.
load_statement -> distribution_setting    : '$1'.
load_statement -> retry_setting           : '$1'.
load_statement -> stop_if_setting         : '$1'.

warmup_setting -> 'warmup' time_literal ';' :
    n(warmup, '$1', [{value, '$2'}]).
curves_setting -> 'curves' '{' curve_definitions '}' :
    n(curves, '$1', [{definitions, '$3'}]).
stages_setting -> 'stages' '[' stage_list ']' :
    n(stages, '$1', [{stages, '$3'}]).
stages_setting -> 'stages' '[' stage_list ',' ']' :
    n(stages, '$1', [{stages, '$3'}]).
think_time_setting -> 'thinkTime' time_literal ';' :
    n(think_time, '$1', [{value, '$2'}]).
request_timeout_setting -> 'requestTimeout' time_literal ';' :
    n(request_timeout, '$1', [{value, '$2'}]).
distribution_setting -> 'distribution' '{' distribution_entries '}' :
    n(distribution, '$1', [{entries, '$3'}]).
stop_if_setting -> 'stopIf' expression ';' :
    n(stop_if, '$1', [{condition, '$2'}]).
retry_setting -> 'retry' '{' retry_entries '}' :
    n(retry, '$1', [{entries, '$3'}]).

%% ---------- Curves ----------

curve_definitions -> '$empty'                            : [].
curve_definitions -> curve_definition curve_definitions : ['$1' | '$2'].

curve_definition -> ident '(' ')' '=' expression ';' :
    n(curve_definition, loc('$1'), [{name, val('$1')}, {params, []}, {body, '$5'}]).
curve_definition -> ident '(' parameter_list ')' '=' expression ';' :
    n(curve_definition, loc('$1'), [{name, val('$1')}, {params, '$3'}, {body, '$6'}]).

parameter_list -> ident                    : [val('$1')].
parameter_list -> ident ',' parameter_list : [val('$1') | '$3'].

%% ---------- Stages ----------

stage_list -> stage                : ['$1'].
stage_list -> stage_list ',' stage : '$1' ++ ['$3'].

stage -> ramp_stage : '$1'.
stage -> hold_stage : '$1'.
stage -> now_stage  : '$1'.

ramp_stage -> users_literal 'in' stage_length :
    n(ramp_stage, loc('$1'), [{users, '$1'}, {duration, '$3'}, {curve, nil}]).
ramp_stage -> users_literal 'in' stage_length curve :
    n(ramp_stage, loc('$1'), [{users, '$1'}, {duration, '$3'}, {curve, '$4'}]).

hold_stage -> users_literal 'for' stage_length :
    n(hold_stage, loc('$1'), [{users, '$1'}, {duration, '$3'}]).

%% Change the user count at once, no length and no curve (C127).
now_stage -> users_literal 'now' :
    n(now_stage, loc('$1'), [{users, '$1'}]).

%% A Time or an iteration count (C101). The count is not a general value.
stage_length -> time_literal       : '$1'.
stage_length -> iterations_literal : '$1'.

%% args is nil when the curve is written without parentheses.
curve -> ident :
    n(curve_ref, loc('$1'), [{name, val('$1')}, {args, nil}]).
curve -> ident '(' ')' :
    n(curve_ref, loc('$1'), [{name, val('$1')}, {args, []}]).
curve -> ident '(' argument_list ')' :
    n(curve_ref, loc('$1'), [{name, val('$1')}, {args, '$3'}]).

%% ---------- Distribution ----------

distribution_entries -> distribution_entry                      : ['$1'].
distribution_entries -> distribution_entry distribution_entries : ['$1' | '$2'].

distribution_entry -> target_name percentage_literal ';' :
    n(distribution_entry, loc('$1'), [{target, val('$1')}, {percentage, '$2'}]).

target_name -> ident : '$1'.

%% ---------- Retry ----------

retry_entries -> '$empty'                  : [].
retry_entries -> retry_entry retry_entries : ['$1' | '$2'].

retry_entry -> attempts_setting : '$1'.
retry_entry -> delay_setting    : '$1'.
retry_entry -> backoff_setting  : '$1'.

attempts_setting -> 'attempts' integer ';'        : n(attempts, '$1', [{value, '$2'}]).
delay_setting    -> 'delay' time_literal ';'      : n(delay, '$1', [{value, '$2'}]).
backoff_setting  -> 'backoff' backoff_strategy ';' : n(backoff, '$1', [{strategy, '$2'}]).

backoff_strategy -> 'fixed'       : fixed.
backoff_strategy -> 'linear'      : linear.
backoff_strategy -> 'exponential' : exponential.

%% ---------- Expressions ----------
%% Precedence, loosest first:
%%   ||   &&   comparisons   + -   * /   unary - !   ^   . and calls
%% ^ is right-associative; comparisons do not chain.

expression -> lambda        : '$1'.
expression -> or_expression : '$1'.

%% ---------- Lambdas and map ----------

lambda -> '\\' lambda_parameters '->' expression :
    n(lambda, '$1', [{params, '$2'}, {body, '$4'}]).

lambda_parameters -> lambda_parameter                  : ['$1'].
lambda_parameters -> '(' lambda_parameter_list ')'     : '$2'.

lambda_parameter_list -> lambda_parameter                           : ['$1'].
lambda_parameter_list -> lambda_parameter ',' lambda_parameter_list : ['$1' | '$3'].

lambda_parameter -> ident :
    n(lambda_param, loc('$1'), [{name, val('$1')}, {type, nil}]).
lambda_parameter -> ident ':' type :
    n(lambda_param, loc('$1'), [{name, val('$1')}, {type, '$3'}]).

%% list_operation returns {Op, Loc, Init, Fun}; postfix applies it.
list_operation -> '.' 'map' '(' function_value ')'    : {map, loc('$2'), nil, '$4'}.
list_operation -> '.' 'filter' '(' function_value ')' : {filter, loc('$2'), nil, '$4'}.
list_operation -> '.' fold_name '(' expression ',' function_value ')' :
    {element(1, '$2'), element(2, '$2'), '$4', '$6'}.

fold_name -> 'fold'  : {fold, loc('$1')}.
fold_name -> 'foldl' : {foldl, loc('$1')}.
fold_name -> 'foldr' : {foldr, loc('$1')}.

function_value -> lambda : '$1'.
function_value -> ident  : var('$1').

or_expression -> and_expression                     : '$1'.
or_expression -> or_expression '||' and_expression  : binary('$2', '$1', '$3').

and_expression -> comparison                        : '$1'.
and_expression -> and_expression '&&' comparison    : binary('$2', '$1', '$3').

comparison -> sum                                   : '$1'.
comparison -> sum comparison_operator sum           : binary('$2', '$1', '$3').

comparison_operator -> '>=' : '$1'.
comparison_operator -> '<=' : '$1'.
comparison_operator -> '>'  : '$1'.
comparison_operator -> '<'  : '$1'.
comparison_operator -> '==' : '$1'.
comparison_operator -> '!=' : '$1'.

sum -> product                                      : '$1'.
sum -> sum '+' product                              : binary('$2', '$1', '$3').
sum -> sum '-' product                              : binary('$2', '$1', '$3').

product -> factor                                   : '$1'.
product -> product '*' factor                       : binary('$2', '$1', '$3').
product -> product '/' factor                       : binary('$2', '$1', '$3').

factor -> exponent                                  : '$1'.
factor -> '-' exponent                              : unary('$1', '$2').
factor -> '!' exponent                              : unary('$1', '$2').

exponent -> postfix                                 : '$1'.
exponent -> postfix '^' factor                      : binary('$2', '$1', '$3').

%% Member access, calls, indexing and list operations chain left to right.
postfix -> primary                                  : '$1'.
postfix -> postfix postfix_operation                : apply_postfix('$1', '$2').

postfix_operation -> list_operation                 : '$1'.
postfix_operation -> '.' member_name                : {member, loc('$1'), val('$2')}.
postfix_operation -> '(' ')'                        : {call, loc('$1'), []}.
postfix_operation -> '(' argument_list ')'          : {call, loc('$1'), '$2'}.
postfix_operation -> '[' expression ']'             : {index, loc('$1'), '$2'}.

argument_list -> expression                         : ['$1'].
argument_list -> argument_list ',' expression       : '$1' ++ ['$3'].

primary -> literal                                  : '$1'.
primary -> match_expression                         : '$1'.
primary -> metric                                   : '$1'.
primary -> json_object                              : '$1'.
primary -> json_array                               : '$1'.
primary -> ident                                    : var('$1').
primary -> 'http'                                   : n(http, '$1', []).
primary -> '(' expression ')'                       : '$2'.

%% ---------- Expression without a leading JSON object (match arm body) ----

expression_nb -> lambda                                   : '$1'.
expression_nb -> or_expression_nb                         : '$1'.
or_expression_nb -> and_expression_nb                     : '$1'.
or_expression_nb -> or_expression_nb '||' and_expression  : binary('$2', '$1', '$3').
and_expression_nb -> comparison_nb                        : '$1'.
and_expression_nb -> and_expression_nb '&&' comparison    : binary('$2', '$1', '$3').
comparison_nb -> sum_nb                                   : '$1'.
comparison_nb -> sum_nb comparison_operator sum           : binary('$2', '$1', '$3').
sum_nb -> product_nb                                      : '$1'.
sum_nb -> sum_nb '+' product                              : binary('$2', '$1', '$3').
sum_nb -> sum_nb '-' product                              : binary('$2', '$1', '$3').
product_nb -> factor_nb                                   : '$1'.
product_nb -> product_nb '*' factor                       : binary('$2', '$1', '$3').
product_nb -> product_nb '/' factor                       : binary('$2', '$1', '$3').
factor_nb -> exponent_nb                                  : '$1'.
factor_nb -> '-' exponent                                 : unary('$1', '$2').
factor_nb -> '!' exponent                                 : unary('$1', '$2').
exponent_nb -> postfix_nb                                 : '$1'.
exponent_nb -> postfix_nb '^' factor                      : binary('$2', '$1', '$3').
postfix_nb -> primary_nb                                  : '$1'.
postfix_nb -> postfix_nb postfix_operation                : apply_postfix('$1', '$2').
primary_nb -> literal                                     : '$1'.
primary_nb -> match_expression                            : '$1'.
primary_nb -> metric                                      : '$1'.
primary_nb -> json_array                                  : '$1'.
primary_nb -> ident                                       : var('$1').
primary_nb -> 'http'                                      : n(http, '$1', []).
primary_nb -> '(' expression ')'                          : '$2'.

%% ---------- Expression without a leading match (expression statement) ----

expression_nm -> lambda                                   : '$1'.
expression_nm -> or_expression_nm                         : '$1'.
or_expression_nm -> and_expression_nm                     : '$1'.
or_expression_nm -> or_expression_nm '||' and_expression  : binary('$2', '$1', '$3').
and_expression_nm -> comparison_nm                        : '$1'.
and_expression_nm -> and_expression_nm '&&' comparison    : binary('$2', '$1', '$3').
comparison_nm -> sum_nm                                   : '$1'.
comparison_nm -> sum_nm comparison_operator sum           : binary('$2', '$1', '$3').
sum_nm -> product_nm                                      : '$1'.
sum_nm -> sum_nm '+' product                              : binary('$2', '$1', '$3').
sum_nm -> sum_nm '-' product                              : binary('$2', '$1', '$3').
product_nm -> factor_nm                                   : '$1'.
product_nm -> product_nm '*' factor                       : binary('$2', '$1', '$3').
product_nm -> product_nm '/' factor                       : binary('$2', '$1', '$3').
factor_nm -> exponent_nm                                  : '$1'.
factor_nm -> '-' exponent                                 : unary('$1', '$2').
factor_nm -> '!' exponent                                 : unary('$1', '$2').
exponent_nm -> postfix_nm                                 : '$1'.
exponent_nm -> postfix_nm '^' factor                      : binary('$2', '$1', '$3').
postfix_nm -> primary_nm                                  : '$1'.
postfix_nm -> postfix_nm postfix_operation                : apply_postfix('$1', '$2').
primary_nm -> literal                                     : '$1'.
primary_nm -> metric                                      : '$1'.
primary_nm -> json_object                                 : '$1'.
primary_nm -> json_array                                  : '$1'.
primary_nm -> ident                                       : var('$1').
primary_nm -> 'http'                                      : n(http, '$1', []).
primary_nm -> '(' expression ')'                          : '$2'.

%% ---------- JSON ----------
%% A "{" right after a complete expression starts a block (if, while,
%% for, match); a "{" where a value is expected starts a JSON object.

json_object -> '{' '}'                  : n(json_object, '$1', [{members, []}]).
json_object -> '{' json_members '}'     : n(json_object, '$1', [{members, '$2'}]).
json_object -> '{' json_members ',' '}' : n(json_object, '$1', [{members, '$2'}]).

json_members -> json_member                  : ['$1'].
json_members -> json_members ',' json_member : '$1' ++ ['$3'].

json_member -> quoted_string ':' json_value :
    n(json_member, loc('$1'), [{key, string_value('$1')}, {value, '$3'}]).

json_array -> '[' ']'                 : n(json_array, '$1', [{items, []}]).
json_array -> '[' json_values ']'     : n(json_array, '$1', [{items, '$2'}]).
json_array -> '[' json_values ',' ']' : n(json_array, '$1', [{items, '$2'}]).

json_values -> json_value                 : ['$1'].
json_values -> json_values ',' json_value : '$1' ++ ['$3'].

%% null exists only as a JSON value (C69).
json_value -> expression : '$1'.
json_value -> 'null'     : n(null, '$1', []).

%% ---------- Metrics ----------

metric -> latency_metric    : '$1'.
metric -> throughput_metric : '$1'.
metric -> errors_metric     : '$1'.
metric -> energy_metric     : '$1'.
metric -> power_metric      : '$1'.
metric -> carbon_metric     : '$1'.
metric -> asserts_metric    : '$1'.
metric -> checks_metric     : '$1'.

latency_metric -> 'latency' '.' latency_measurement '(' ')' :
    metric('$1', '$3', nil).
latency_metric -> 'latency' '.' 'percentile' '(' number_literal ')' :
    metric('$1', '$3', '$5').

latency_measurement -> 'p50'  : '$1'.
latency_measurement -> 'p90'  : '$1'.
latency_measurement -> 'p95'  : '$1'.
latency_measurement -> 'p99'  : '$1'.
latency_measurement -> 'mean' : '$1'.
latency_measurement -> 'min'  : '$1'.
latency_measurement -> 'max'  : '$1'.

throughput_metric -> 'throughput' '.' 'perSecond' '(' ')' : metric('$1', '$3', nil).

errors_metric -> 'errors' '.' errors_measurement '(' ')' : metric('$1', '$3', nil).
errors_measurement -> 'rate'             : '$1'.
errors_measurement -> 'count'            : '$1'.
errors_measurement -> 'timeouts'         : '$1'.
errors_measurement -> 'connectionErrors' : '$1'.
errors_measurement -> 'assertFailures'   : '$1'.
errors_measurement -> 'checkFailures'    : '$1'.

energy_metric -> 'energy' '.' energy_measurement '(' ')' : metric('$1', '$3', nil).
energy_measurement -> 'total'      : '$1'.
energy_measurement -> 'perRequest' : '$1'.
energy_measurement -> 'perUser'    : '$1'.

power_metric -> 'power' '.' power_measurement '(' ')' : metric('$1', '$3', nil).
power_measurement -> 'mean' : '$1'.
power_measurement -> 'peak' : '$1'.

carbon_metric -> 'carbon' '.' carbon_measurement '(' ')' : metric('$1', '$3', nil).
carbon_measurement -> 'total'      : '$1'.
carbon_measurement -> 'perRequest' : '$1'.

%% Failed asserts, counted apart from HTTP errors (C118).
asserts_metric -> 'asserts' '.' asserts_measurement '(' ')' : metric('$1', '$3', nil).
asserts_measurement -> 'failed' : '$1'.
asserts_measurement -> 'rate'   : '$1'.

%% Failed checks, the soft asserts (C130).
checks_metric -> 'checks' '.' checks_measurement '(' ')' : metric('$1', '$3', nil).
checks_measurement -> 'failed' : '$1'.
checks_measurement -> 'rate'   : '$1'.

%% ---------- Literals ----------

literal -> time_literal       : '$1'.
literal -> energy_literal     : '$1'.
literal -> power_literal      : '$1'.
literal -> carbon_literal     : '$1'.
literal -> users_literal      : '$1'.
literal -> percentage_literal : '$1'.
literal -> number_literal     : '$1'.
literal -> string_literal     : '$1'.
literal -> bool_literal       : '$1'.

time_literal       -> time_lit       : lit(time, '$1').
energy_literal     -> energy_lit     : lit(energy, '$1').
power_literal      -> power_lit      : lit(power, '$1').
carbon_literal     -> carbon_lit     : lit(carbon, '$1').
users_literal      -> users_lit      : lit(users, '$1').
iterations_literal -> iterations_lit : lit(iterations, '$1').
percentage_literal -> percentage_lit : lit(percentage, '$1').

number_literal -> int_lit   : lit(number, '$1').
number_literal -> float_lit : lit(number, '$1').

integer -> int_lit : lit(number, '$1').

string_literal -> quoted_string  : lit(string, '$1').
string_literal -> raw_string_lit : lit(raw_string, '$1').

quoted_string -> string_lit : '$1'.

bool_literal -> 'true'  : n(bool_literal, '$1', [{value, true}]).
bool_literal -> 'false' : n(bool_literal, '$1', [{value, false}]).

%% ---------- Statements ----------

statements -> '$empty'            : [].
statements -> statement statements : ['$1' | '$2'].

statement -> let_statement        : '$1'.
statement -> assignment_statement : '$1'.
statement -> assert_statement     : '$1'.
statement -> check_statement      : '$1'.
statement -> if_statement         : '$1'.
statement -> while_statement      : '$1'.
statement -> for_statement        : '$1'.
statement -> match_statement      : '$1'.
statement -> return_statement     : '$1'.
statement -> expression_statement : '$1'.

let_statement -> 'let' ident '=' expression ';' :
    let_stmt('$1', false, '$2', nil, '$4').
let_statement -> 'let' ident ':' type '=' expression ';' :
    let_stmt('$1', false, '$2', '$4', '$6').
let_statement -> 'let' 'mut' ident '=' expression ';' :
    let_stmt('$1', true, '$3', nil, '$5').
let_statement -> 'let' 'mut' ident ':' type '=' expression ';' :
    let_stmt('$1', true, '$3', '$5', '$7').

assignment_statement -> ident '=' expression ';' :
    n(assign, loc('$1'), [{name, val('$1')}, {value, '$3'}]).

%% Must be a call; checked after parsing (C63).
expression_statement -> expression_nm ';' :
    n(expression_statement, loc('$1'), [{expression, '$1'}]).

assert_statement -> 'assert' expression ';' :
    n(assert, '$1', [{condition, '$2'}]).

%% A soft assert: stops nothing, never fails the Test (C129).
check_statement -> 'check' expression ';' :
    n(check, '$1', [{condition, '$2'}]).

type_name -> ident : '$1'.

type -> type_name :
    n(type, loc('$1'), [{name, val('$1')}, {args, []}]).
type -> type_name '<' type_list '>' :
    n(type, loc('$1'), [{name, val('$1')}, {args, '$3'}]).

type_list -> type               : ['$1'].
type_list -> type ',' type_list : ['$1' | '$3'].

%% ---------- Control flow ----------

block -> '{' statements '}' : n(block, '$1', [{statements, '$2'}]).

if_statement -> 'if' expression block :
    n('if', '$1', [{condition, '$2'}, {then, '$3'}, {'else', nil}]).
if_statement -> 'if' expression block 'else' block :
    n('if', '$1', [{condition, '$2'}, {then, '$3'}, {'else', '$5'}]).
if_statement -> 'if' expression block 'else' if_statement :
    n('if', '$1', [{condition, '$2'}, {then, '$3'}, {'else', '$5'}]).

while_statement -> 'while' expression block :
    n('while', '$1', [{condition, '$2'}, {body, '$3'}]).

for_statement -> 'for' ident 'in' expression block :
    n('for', '$1', [{var, val('$2')}, {iterable, '$4'}, {body, '$5'}]).

match_expression -> 'match' expression '{' match_arms '}' :
    n(match, '$1', [{subject, '$2'}, {arms, '$4'}]).
match_expression -> 'match' expression '{' match_arms ',' '}' :
    n(match, '$1', [{subject, '$2'}, {arms, '$4'}]).

match_arms -> match_arm                : ['$1'].
match_arms -> match_arms ',' match_arm : '$1' ++ ['$3'].

match_arm -> pattern '=>' match_arm_body :
    n(match_arm, loc('$1'), [{pattern, '$1'}, {guard, nil}, {body, '$3'}]).
match_arm -> pattern 'if' expression '=>' match_arm_body :
    n(match_arm, loc('$1'), [{pattern, '$1'}, {guard, '$3'}, {body, '$5'}]).

%% A "{" after "=>" always starts a block.
match_arm_body -> block         : '$1'.
match_arm_body -> expression_nb : '$1'.

pattern -> literal     : n(literal_pattern, loc('$1'), [{negative, false}, {literal, '$1'}]).
pattern -> '-' literal : n(literal_pattern, loc('$1'), [{negative, true}, {literal, '$2'}]).
pattern -> ident       : n(bind_pattern, loc('$1'), [{name, val('$1')}]).
pattern -> '_'         : n(wildcard_pattern, loc('$1'), []).

%% A match on its own as a statement needs no ";" (one is accepted).
match_statement -> match_expression :
    n(match_statement, loc('$1'), [{match, '$1'}]).
match_statement -> match_expression ';' :
    n(match_statement, loc('$1'), [{match, '$1'}]).

%% Only allowed inside a function; checked after parsing (C74).
return_statement -> 'return' ';'            : n(return, '$1', [{value, nil}]).
return_statement -> 'return' expression ';' : n(return, '$1', [{value, '$2'}]).

%% ---------- Suite functions ----------

functions_block -> 'Functions' '{' fn_declarations '}' : '$3'.

fn_declarations -> '$empty'                       : [].
fn_declarations -> fn_declaration fn_declarations : ['$1' | '$2'].

fn_declaration -> 'fn' ident '(' ')' ':' type block :
    fn_decl('$1', '$2', [], '$6', '$7').
fn_declaration -> 'fn' ident '(' fn_parameter_list ')' ':' type block :
    fn_decl('$1', '$2', '$4', '$7', '$8').

fn_parameter_list -> fn_parameter                       : ['$1'].
fn_parameter_list -> fn_parameter ',' fn_parameter_list : ['$1' | '$3'].

fn_parameter -> ident ':' type :
    n(param, loc('$1'), [{name, val('$1')}, {type, '$3'}]).

%% ---------- Lexical ----------

%% A member name after ".": any name, plus the metric group names, so a
%% Response can have a latency field (C111), and http, so a target can
%% have an http client (C112). They stay reserved elsewhere.
member_name -> ident        : '$1'.
member_name -> 'http'       : '$1'.
member_name -> 'latency'    : '$1'.
member_name -> 'throughput' : '$1'.
member_name -> 'errors'     : '$1'.
member_name -> 'energy'     : '$1'.
member_name -> 'power'      : '$1'.
member_name -> 'carbon'     : '$1'.
member_name -> 'asserts'    : '$1'.
member_name -> 'checks'     : '$1'.

name -> ident : '$1'.

%% identifier, plus the contextual keywords (C77): they only have meaning
%% in one position and stay usable as names everywhere else.
ident -> identifier     : '$1'.
ident -> 'warmup'       : '$1'.
ident -> 'curves'       : '$1'.
ident -> 'stages'       : '$1'.
ident -> 'now'          : '$1'.
ident -> 'thinkTime'    : '$1'.
ident -> 'requestTimeout' : '$1'.
ident -> 'distribution' : '$1'.
ident -> 'retry'        : '$1'.
ident -> 'stopIf'       : '$1'.
ident -> 'attempts'     : '$1'.
ident -> 'delay'        : '$1'.
ident -> 'backoff'      : '$1'.
ident -> 'sut'          : '$1'.
ident -> 'baseUrl'      : '$1'.
ident -> 'host'         : '$1'.
ident -> 'samples'      : '$1'.
ident -> 'topics' : '$1'.
ident -> 'mqtt' : '$1'.
ident -> 'broker' : '$1'.
ident -> 'qos' : '$1'.
ident -> 'metrics' : '$1'.
ident -> 'metricsPort' : '$1'.
ident -> 'monitoring' : '$1'.
ident -> 'interval' : '$1'.
ident -> 'port' : '$1'.
ident -> 'path' : '$1'.
ident -> 'format' : '$1'.
ident -> 'carbonIntensity' : '$1'.
ident -> 'output'       : '$1'.
ident -> 'requests'     : '$1'.
ident -> 'summary'      : '$1'.
ident -> 'file'         : '$1'.
ident -> 'fields'       : '$1'.
ident -> 'includeWarmup' : '$1'.
ident -> 'runs'         : '$1'.
ident -> 'cooldown'     : '$1'.
ident -> 'discard'      : '$1'.
ident -> 'fixed'        : '$1'.
ident -> 'linear'       : '$1'.
ident -> 'exponential'  : '$1'.
ident -> 'p50'          : '$1'.
ident -> 'p90'          : '$1'.
ident -> 'p95'          : '$1'.
ident -> 'p99'          : '$1'.
ident -> 'mean'         : '$1'.
ident -> 'min'          : '$1'.
ident -> 'max'          : '$1'.
ident -> 'percentile'   : '$1'.
ident -> 'perSecond'    : '$1'.
ident -> 'rate'         : '$1'.
ident -> 'count'        : '$1'.
ident -> 'timeouts'     : '$1'.
ident -> 'connectionErrors' : '$1'.
ident -> 'assertFailures' : '$1'.
ident -> 'checkFailures' : '$1'.
ident -> 'total'        : '$1'.
ident -> 'perRequest'   : '$1'.
ident -> 'perUser'      : '$1'.
ident -> 'peak'         : '$1'.
ident -> 'failed'       : '$1'.

Erlang code.

-define(AST, 'Elixir.PerfLang.AST').

%% Tokens are {Category, {Line, Column}, Value} (see PerfLang.Lexer).
loc({_, Loc, _}) -> Loc;
loc(#{loc := Loc}) -> Loc;
loc({_, _} = Loc) -> Loc.

val({_, _, Value}) -> Value.


n(Kind, Loc, Fields) -> ?AST:new(Kind, loc(Loc), Fields).

lit(Kind, Token) -> ?AST:literal(Kind, loc(Token), val(Token)).

string_value(Token) -> val(Token).

var(Token) -> n(var, loc(Token), [{name, val(Token)}]).

binary(Op, Left, Right) ->
    n(binary, Op, [{op, element(1, Op)}, {left, Left}, {right, Right}]).

unary(Op, Operand) ->
    n(unary, Op, [{op, element(1, Op)}, {operand, Operand}]).

apply_postfix(Object, {member, Loc, Name}) ->
    n(member, Loc, [{object, Object}, {name, Name}]);
apply_postfix(Callee, {call, Loc, Args}) ->
    n(call, Loc, [{callee, Callee}, {args, Args}]);
apply_postfix(Object, {index, Loc, Index}) ->
    n(index, Loc, [{object, Object}, {index, Index}]);
apply_postfix(Receiver, {Op, Loc, Init, Fun}) ->
    n(list_operation, Loc, [{op, Op}, {receiver, Receiver}, {init, Init}, {function, Fun}]).

metric(Group, Measurement, Arg) ->
    n(metric, Group, [{group, element(1, Group)},
                      {measurement, element(1, Measurement)},
                      {argument, Arg}]).

phase(Kind, Keyword, Statements) ->
    n(phase, Keyword, [{kind, Kind}, {statements, Statements}]).

suite(Keyword, Name, Config, Functions, {Load, Tests}) ->
    n(test_suite, Keyword, [{name, val(Name)}, {config, Config},
                            {functions, Functions}, {load, Load},
                            {tests, Tests}]).

test(Keyword, Name, Load, {Setup, Actions, Verify, Cleanup}) ->
    n(test, Keyword, [{name, val(Name)}, {load, Load}, {setup, Setup},
                      {actions, Actions}, {verify, Verify}, {cleanup, Cleanup}]).

let_stmt(Keyword, Mutable, Name, Type, Value) ->
    n('let', Keyword, [{mutable, Mutable}, {name, val(Name)},
                       {type, Type}, {value, Value}]).

fn_decl(Keyword, Name, Params, ReturnType, Body) ->
    n(fn_declaration, Keyword, [{name, val(Name)}, {params, Params},
                                {return_type, ReturnType}, {body, Body}]).
