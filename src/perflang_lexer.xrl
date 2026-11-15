%% PerfLang lexer (leex), from perflang.ebnf "Literals" and "Lexical".
%%
%% Every token, including whitespace and comments, is returned as
%%   {Category, Line, Chars}
%% PerfLang.Lexer walks that list to compute exact line/column positions
%% (portable across OTP versions), drops whitespace and comments, turns
%% the raw characters into values, and reports lexical errors.
%%
%% Lexical errors are not raised here. Rules that recognise a known
%% mistake return {lex_error, Line, {Kind, Chars}} so PerfLang.Lexer can
%% report it with a column and a clear message.

Definitions.

D       = [0-9]
L       = [A-Za-z]
INT     = {D}+
NUM     = {D}+(\.{D}+)?
ID      = {L}({L}|{D}|_)*

%% time literal (C15, C29): parts largest first, each at most once.
%% Range limits (C31, C80) and decimals only in the last part (C81) are
%% checked after parsing.
H       = {NUM}h
MI      = {NUM}m
S       = {NUM}s
MS      = {NUM}ms
TIME    = {H}({MI})?({S})?({MS})?|{MI}({S})?({MS})?|{S}({MS})?|{MS}

Rules.

%% ---------- Whitespace and comments ----------

[\s\t\r\n]+                         : {token, {whitespace, TokenLine, TokenChars}}.
//[^\n]*                            : {token, {comment, TokenLine, TokenChars}}.
/\*([^*]|\*+[^*/])*\*+/             : {token, {comment, TokenLine, TokenChars}}.
/\*([^*]|\*+[^*/])*\**              : {token, {lex_error, TokenLine, {unterminated_comment, TokenChars}}}.

%% ---------- Strings (C64, C65) ----------

%% raw string: """ ... """, may span lines, no escapes.
"""([^"]|"[^"]|""[^"])*("|"")?"""   : {token, {raw_string_lit, TokenLine, TokenChars}}.
"""([^"]|"[^"]|""[^"])*("|"")?      : {token, {lex_error, TokenLine, {unterminated_raw_string, TokenChars}}}.

%% quoted string: one line, escapes \" \\ \n \t.
"([^"\\\n]|\\["\\nt])*"             : {token, {string_lit, TokenLine, TokenChars}}.
"([^"\\\n]|\\[^\n])*"               : {token, {lex_error, TokenLine, {bad_escape, TokenChars}}}.
"([^"\\\n]|\\[^\n])*\\?             : {token, {lex_error, TokenLine, {unterminated_string, TokenChars}}}.

%% ---------- Literals with units (C14, C15, C29, C40-C42, C94) ----------
%% Units are case-sensitive and read longest-match first, so 5ms is
%% milliseconds, 5mJ millijoules and 5mW milliwatts.

{TIME}                              : {token, {time_lit, TokenLine, TokenChars}}.
{NUM}(mJ|J|kJ|MJ|Wh|kWh|MWh)        : {token, {energy_lit, TokenLine, TokenChars}}.
{NUM}(mW|W|kW)                      : {token, {power_lit, TokenLine, TokenChars}}.
{NUM}(mgCO2e|gCO2e|kgCO2e)          : {token, {carbon_lit, TokenLine, TokenChars}}.
{NUM}gCO2e/kWh                      : {token, {carbon_intensity_lit, TokenLine, TokenChars}}.
{INT}vu                             : {token, {users_lit, TokenLine, TokenChars}}.
{D}+\.{D}+vu                        : {token, {lex_error, TokenLine, {fractional_users, TokenChars}}}.

%% iteration count (C102): a stage length only, whole numbers. iter/vu is a
%% count per virtual user, one token like gCO2e/kWh (C175).
{INT}iter                           : {token, {iterations_lit, TokenLine, TokenChars}}.
{INT}iter/vu                        : {token, {iterations_lit, TokenLine, TokenChars}}.
{D}+\.{D}+iter(/vu)?                : {token, {lex_error, TokenLine, {fractional_iterations, TokenChars}}}.

%% percentage literal (C34, C35, C82): at most two decimal places.
{INT}(\.{D}{D}?)?%                  : {token, {percentage_lit, TokenLine, TokenChars}}.
{D}+\.{D}+%                         : {token, {lex_error, TokenLine, {percentage_decimals, TokenChars}}}.

%% A number directly followed by letters that are not a unit.
{NUM}{L}({L}|{D}|_)*                : {token, {lex_error, TokenLine, {unknown_unit, TokenChars}}}.

%% number literal (C57)
{D}+\.{D}+                          : {token, {float_lit, TokenLine, TokenChars}}.
{INT}                               : {token, {int_lit, TokenLine, TokenChars}}.

%% ---------- Identifiers and keywords (C8, C77) ----------

{ID}                                : {token, identifier(TokenChars, TokenLine)}.
_                                   : {token, {'_', TokenLine, TokenChars}}.
_({L}|{D}|_)+                       : {token, {lex_error, TokenLine, {underscore_identifier, TokenChars}}}.

%% ---------- Operators and punctuation ----------

\|\|                                : {token, {'||', TokenLine, TokenChars}}.
&&                                  : {token, {'&&', TokenLine, TokenChars}}.
>=                                  : {token, {'>=', TokenLine, TokenChars}}.
<=                                  : {token, {'<=', TokenLine, TokenChars}}.
==                                  : {token, {'==', TokenLine, TokenChars}}.
!=                                  : {token, {'!=', TokenLine, TokenChars}}.
!                                   : {token, {'!', TokenLine, TokenChars}}.
=>                                  : {token, {'=>', TokenLine, TokenChars}}.
->                                  : {token, {'->', TokenLine, TokenChars}}.
>                                   : {token, {'>', TokenLine, TokenChars}}.
<                                   : {token, {'<', TokenLine, TokenChars}}.
=                                   : {token, {'=', TokenLine, TokenChars}}.
\+                                  : {token, {'+', TokenLine, TokenChars}}.
-                                   : {token, {'-', TokenLine, TokenChars}}.
\*                                  : {token, {'*', TokenLine, TokenChars}}.
/                                   : {token, {'/', TokenLine, TokenChars}}.
\^                                  : {token, {'^', TokenLine, TokenChars}}.
\.                                  : {token, {'.', TokenLine, TokenChars}}.
,                                   : {token, {',', TokenLine, TokenChars}}.
;                                   : {token, {';', TokenLine, TokenChars}}.
:                                   : {token, {':', TokenLine, TokenChars}}.
\(                                  : {token, {'(', TokenLine, TokenChars}}.
\)                                  : {token, {')', TokenLine, TokenChars}}.
\[                                  : {token, {'[', TokenLine, TokenChars}}.
\]                                  : {token, {']', TokenLine, TokenChars}}.
\{                                  : {token, {'{', TokenLine, TokenChars}}.
\}                                  : {token, {'}', TokenLine, TokenChars}}.
\\                                  : {token, {'\\', TokenLine, TokenChars}}.

%% Anything else.
.                                   : {token, {lex_error, TokenLine, {illegal_character, TokenChars}}}.

Erlang code.

%% Reserved words (C77). They cannot be used as names.
reserved("let")         -> true;
reserved("mut")         -> true;
reserved("fn")          -> true;
reserved("if")          -> true;
reserved("else")        -> true;
reserved("while")       -> true;
reserved("for")         -> true;
reserved("in")          -> true;
reserved("match")       -> true;
reserved("return")      -> true;
reserved("assert")      -> true;
reserved("check")       -> true;
reserved("map")         -> true;
reserved("filter")      -> true;
reserved("fold")        -> true;
reserved("foldl")       -> true;
reserved("foldr")       -> true;
reserved("true")        -> true;
reserved("false")       -> true;
reserved("null")        -> true;
reserved("TestSuite")   -> true;
reserved("Test")        -> true;
reserved("Load")        -> true;
reserved("Setup")       -> true;
reserved("Actions")     -> true;
reserved("Verify")      -> true;
reserved("Cleanup")     -> true;
reserved("Functions")   -> true;
reserved("Config")      -> true;
reserved("latency")     -> true;
reserved("throughput")  -> true;
reserved("errors")      -> true;
reserved("energy")      -> true;
reserved("power")       -> true;
reserved("carbon")      -> true;
reserved("http")        -> true;
reserved("asserts")     -> true;
reserved("checks")      -> true;
reserved(_)             -> false.

%% Contextual keywords (C77): Load, retry and Config settings,
%% measurements and backoff strategies. They get their own token so the parser can match
%% them in the one position where they have meaning; everywhere else the
%% parser accepts them as ordinary names (see `ident` in the parser).
contextual("warmup")        -> true;
contextual("curves")        -> true;
contextual("stages")        -> true;
contextual("now")           -> true;
contextual("thinkTime")     -> true;
contextual("requestTimeout") -> true;
contextual("distribution")  -> true;
contextual("retry")         -> true;
contextual("stopIf")        -> true;
contextual("attempts")      -> true;
contextual("delay")         -> true;
contextual("backoff")       -> true;
contextual("sut")           -> true;
contextual("baseUrl")       -> true;
contextual("host")          -> true;
contextual("samples")       -> true;
contextual("topics")        -> true;
contextual("mqtt")          -> true;
contextual("broker")        -> true;
contextual("qos")           -> true;
contextual("metrics")       -> true;
contextual("metricsPort")   -> true;
contextual("monitoring")    -> true;
contextual("interval")      -> true;
contextual("port")          -> true;
contextual("path")          -> true;
contextual("format")        -> true;
contextual("carbonIntensity")-> true;
contextual("output")        -> true;
contextual("requests")      -> true;
contextual("summary")       -> true;
contextual("file")          -> true;
contextual("fields")        -> true;
contextual("includeWarmup") -> true;
contextual("runs")          -> true;
contextual("workers")       -> true;
contextual("cooldown")      -> true;
contextual("discard")       -> true;
contextual("fixed")         -> true;
contextual("linear")        -> true;
contextual("exponential")   -> true;
contextual("p50")           -> true;
contextual("p90")           -> true;
contextual("p95")           -> true;
contextual("p99")           -> true;
contextual("mean")          -> true;
contextual("min")           -> true;
contextual("max")           -> true;
contextual("percentile")    -> true;
contextual("perSecond")     -> true;
contextual("rate")          -> true;
contextual("count")         -> true;
contextual("timeouts")      -> true;
contextual("connectionErrors") -> true;
contextual("assertFailures") -> true;
contextual("checkFailures") -> true;
contextual("total")         -> true;
contextual("perRequest")    -> true;
contextual("perUser")       -> true;
contextual("peak")          -> true;
contextual("failed")        -> true;
contextual(_)               -> false.

identifier(Chars, Line) ->
    case reserved(Chars) orelse contextual(Chars) of
        true  -> {list_to_atom(Chars), Line, Chars};
        false -> {identifier, Line, Chars}
    end.
