# Referenzfälle für tactical.R (Gewichts-Erzeuger, Druckausgabe, tactical_simulation).
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_tactical.R
source("golden/modules/ref_tools.R"); ref_init("tactical")

P <- "from simlev import tactical as T\nimport numpy as np, pandas as pd, math\n"
J <- "T = SL.Tactical\n"   # Kopf des Julia-Codes (jl)
cs <- function(id, r, py, inputs = I, jl = NULL, ...) {
  used <- names(inputs)[vapply(names(inputs), function(k) grepl(sprintf("(^|[^A-Za-z0-9_.])%s([^A-Za-z0-9_.]|$)", k), r), TRUE)]
  ref_case(id, r, paste0(P, py), inputs = inputs[used], jl = if (is.null(jl)) NULL else paste0(J, jl), ...)
}

make_mkt <- function(n = 365 * 4, seed = 1) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date("2012-01-01"), by = "day", length.out = n))
  d$A <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)); d$B <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.009))
  d$C <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.004)); d$CASH <- 100 * cumprod(rep(1 + 0.02 / 365, n))
  d
}
d <- make_mkt()
d$infl <- round(2 + cumsum(rnorm(nrow(d), 0, 0.05)), 2)
dna <- d; dna$A[c(1:3, 400:410)] <- NA; dna$B[700] <- NA
set.seed(5)
buy <- runif(nrow(d)) < 0.02; sell <- runif(nrow(d)) < 0.02
I <- list(d = d, buy = buy, sell = sell)

# ── signal_state ─────────────────────────────────────────────────────────────
cs("ss_basic", "signal_state(list(buy = c(F, T, F, F, F, T), sell = c(F, F, F, T, F, F)))",
   "result = T.signal_state({'buy': [False, True, False, False, False, True], 'sell': [False, False, False, True, False, False]})",
   jl = 'result = T.signal_state(SL.RList("buy" => [false, true, false, false, false, true], "sell" => [false, false, false, true, false, false]))')
cs("ss_init", "signal_state(list(buy = c(F, F, T, T, F), sell = c(F, T, T, F, T)), initial = TRUE)",
   "result = T.signal_state({'buy': [False, False, True, True, False], 'sell': [False, True, True, False, True]}, initial=True)",
   jl = 'result = T.signal_state(SL.RList("buy" => [false, false, true, true, false], "sell" => [false, true, true, false, true]); initial = true)')
cs("ss_none", "signal_state(list(buy = c(F, F, F), sell = c(F, F, F)))", "result = T.signal_state({'buy': [False] * 3, 'sell': [False] * 3})",
   jl = 'result = T.signal_state(SL.RList("buy" => fill(false, 3), "sell" => fill(false, 3)))')
cs("ss_long", "signal_state(list(buy = buy, sell = sell))", "result = T.signal_state({'buy': buy, 'sell': sell})",
   jl = 'result = T.signal_state(SL.RList("buy" => buy, "sell" => sell))')
cs("ss_example", "x <- c(100, 102, 105, 103, 99, 97, 100, 104); signal_state(list(buy = x > 101, sell = x < 98))",
   "x = np.array([100, 102, 105, 103, 99, 97, 100, 104.]); result = T.signal_state({'buy': x > 101, 'sell': x < 98})",
   jl = 'x = [100, 102, 105, 103, 99, 97, 100, 104.0]; result = T.signal_state(SL.RList("buy" => x .> 101, "sell" => x .< 98))')

# ── momentum_score ───────────────────────────────────────────────────────────
cs("ms_default", "momentum_score(d, c('A', 'B'))", "result = T.momentum_score(d, ['A', 'B'])",
   jl = 'result = T.momentum_score(d, ["A", "B"])')
cs("ms_lb", "momentum_score(d, c('A', 'B', 'C'), lookbacks = c(1, 12))", "result = T.momentum_score(d, ['A', 'B', 'C'], lookbacks=[1, 12])",
   jl = 'result = T.momentum_score(d, ["A", "B", "C"]; lookbacks = [1, 12])')
cs("ms_13612w", "momentum_score(d, c('A', 'CASH'), type = '13612w')", "result = T.momentum_score(d, ['A', 'CASH'], type='13612w')",
   jl = 'result = T.momentum_score(d, ["A", "CASH"]; type = "13612w")')
cs("ms_single", "momentum_score(d, 'B', lookbacks = 3)", "result = T.momentum_score(d, 'B', lookbacks=3)",
   jl = 'result = T.momentum_score(d, "B"; lookbacks = 3)')
cs("ms_na", "momentum_score(dna, c('A', 'B'), lookbacks = c(1, 2))", "result = T.momentum_score(dna, ['A', 'B'], lookbacks=[1, 2])",
   inputs = list(dna = dna),
   jl = 'result = T.momentum_score(dna, ["A", "B"]; lookbacks = [1, 2])')
dme <- data.frame(date = seq.Date(as.Date("2019-01-01"), as.Date("2021-12-31"), by = "day"))
dme$A <- as.numeric(dme$date - dme$date[1]) + 100
cs("ms_month_end", "momentum_score(dme, 'A', lookbacks = c(1, 12))", "result = T.momentum_score(dme, 'A', lookbacks=[1, 12])", inputs = list(dme = dme),
   jl = 'result = T.momentum_score(dme, "A"; lookbacks = [1, 12])')
wd <- d[!format(d$date, "%u") %in% c("6", "7"), c("date", "A", "B")]
cs("ms_weekdays", "momentum_score(wd, c('A', 'B'), lookbacks = c(1, 6))", "result = T.momentum_score(wd, ['A', 'B'], lookbacks=[1, 6])", inputs = list(wd = wd),
   jl = 'result = T.momentum_score(wd, ["A", "B"]; lookbacks = [1, 6])')
cs("ms_chrdate", "x <- data.frame(date = format(d$date[1:400]), A = d$A[1:400]); momentum_score(x, 'A', lookbacks = 1)",
   "x = pd.DataFrame({'date': [str(v)[:10] for v in d['date'][:400]], 'A': d['A'][:400]}); result = T.momentum_score(x, 'A', lookbacks=1)",
   jl = 'x = SL.RFrame("date" => Dates.format.(d.date[1:400], "yyyy-mm-dd"), "A" => d.A[1:400]); result = T.momentum_score(x, "A"; lookbacks = 1)')
cs("ms_posixct", "x2 <- data.frame(date = as.POSIXct(format(d$date[1:400]), tz = 'Europe/Berlin'), A = d$A[1:400]); momentum_score(x2, 'A', lookbacks = c(1, 2))",
   "x2 = pd.DataFrame({'date': pd.to_datetime(d['date'][:400]).dt.tz_localize('Europe/Berlin'), 'A': d['A'][:400]}); result = T.momentum_score(x2, 'A', lookbacks=[1, 2])",
   jl = 'x2 = SL.RFrame("date" => DateTime.(d.date[1:400]), "A" => d.A[1:400]); result = T.momentum_score(x2, "A"; lookbacks = [1, 2])')
cs("tr_env", "thr <- 101; tactical_rules(d, list(list(when = 'A > thr', weights = c(A = 1, B = 1))), default = c(C = 1))",
   "thr = 101\nresult = T.tactical_rules(d, [{'when': 'A > thr', 'weights': {'A': 1, 'B': 1}}], default={'C': 1})",
   jl = 'thr = 101; result = T.tactical_rules(d, [SL.RList("when" => "A > thr", "weights" => SL.named("A" => 1, "B" => 1))], SL.named("C" => 1); env = @__MODULE__)')
cs("rot_top_frac", "tactical_rotation(d, c('A', 'B', 'C'), top = 2.7, safe = 'CASH', lookbacks = c(2, 4))",
   "result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2.7, safe='CASH', lookbacks=[2, 4])",
   jl = 'result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2.7, safe = "CASH", lookbacks = [2, 4])')
cs("ms_err_miss", "momentum_score(d, c('A', 'X', 'Y'))", "result = T.momentum_score(d, ['A', 'X', 'Y'])",
   jl = 'result = T.momentum_score(d, ["A", "X", "Y"])')
cs("ms_err_type", "momentum_score(d, 'A', type = 'foo')", "result = T.momentum_score(d, 'A', type='foo')",
   jl = 'result = T.momentum_score(d, "A"; type = "foo")')

# ── tactical_rules ───────────────────────────────────────────────────────────
cs("tr_basic", "tactical_rules(d, list(list(when = 'A > B', weights = c(A = 1)), list(when = rep(TRUE, nrow(d)), weights = c(B = 0.5, C = 0.5))),
                 default = c(C = 1))",
   "result = T.tactical_rules(d, [{'when': 'A > B', 'weights': {'A': 1}}, {'when': np.repeat(True, len(d)), 'weights': {'B': 0.5, 'C': 0.5}}],
                    default={'C': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => "A > B", "weights" => SL.named("A" => 1)), SL.RList("when" => fill(true, SL.nrow(d)), "weights" => SL.named("B" => 0.5, "C" => 0.5))], SL.named("C" => 1))')
cs("tr_regime", "attr(tactical_rules(d, list(list(when = 'infl > 2.2', weights = c(C = 0.7, CASH = 0.3)), list(when = 'A > B', weights = c(A = 1))),
                 default = c(B = 2, C = 2)), 'regime')",
   "result = T.tactical_rules(d, [{'when': 'infl > 2.2', 'weights': {'C': 0.7, 'CASH': 0.3}}, {'when': 'A > B', 'weights': {'A': 1}}],
                    default={'B': 2, 'C': 2}).attrs['regime']",
   jl = 'result = SL.attrs(T.tactical_rules(d, [SL.RList("when" => "infl > 2.2", "weights" => SL.named("C" => 0.7, "CASH" => 0.3)), SL.RList("when" => "A > B", "weights" => SL.named("A" => 1))], SL.named("B" => 2, "C" => 2)))["regime"]')
cs("tr_signal", "tactical_rules(d, list(list(when = list(buy = buy, sell = sell), weights = c(A = 0.8, B = 0.2))), default = c(CASH = 1))",
   "result = T.tactical_rules(d, [{'when': {'buy': buy, 'sell': sell}, 'weights': {'A': 0.8, 'B': 0.2}}], default={'CASH': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => SL.RList("buy" => buy, "sell" => sell), "weights" => SL.named("A" => 0.8, "B" => 0.2))], SL.named("CASH" => 1))')
cs("tr_na", "w <- d$A > 105; w[1:50] <- NA; tactical_rules(d, list(list(when = w, weights = c(A = 1))), default = c(C = 1, A = -1))",
   "w = (d['A'] > 105).to_numpy(dtype=object); w[:50] = None\nresult = T.tactical_rules(d, [{'when': w, 'weights': {'A': 1}}], default={'C': 1, 'A': -1})",
   jl = 'w = Union{Missing,Bool}[v for v in (d.A .> 105)]; w[1:50] .= missing
result = T.tactical_rules(d, [SL.RList("when" => w, "weights" => SL.named("A" => 1))], SL.named("C" => 1, "A" => -1))')
cs("tr_empty", "tactical_rules(d, list(), default = c(A = 0.6, C = 0.4))", "result = T.tactical_rules(d, [], default={'A': 0.6, 'C': 0.4})",
   jl = 'result = T.tactical_rules(d, [], SL.named("A" => 0.6, "C" => 0.4))')
cs("tr_err_len", "tactical_rules(d, list(list(when = c(TRUE, FALSE), weights = c(A = 1))), default = c(C = 1))",
   "result = T.tactical_rules(d, [{'when': [True, False], 'weights': {'A': 1}}], default={'C': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => [true, false], "weights" => SL.named("A" => 1))], SL.named("C" => 1))')
cs("tr_err_zero", "tactical_rules(d, list(list(when = 'A > B', weights = c(A = 0))), default = c(C = 1))",
   "result = T.tactical_rules(d, [{'when': 'A > B', 'weights': {'A': 0}}], default={'C': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => "A > B", "weights" => SL.named("A" => 0))], SL.named("C" => 1))')
cs("tr_numeric", "tactical_rules(d, list(list(when = as.numeric(d$A > d$B), weights = c(A = 1))), default = c(C = 1))",
   "result = T.tactical_rules(d, [{'when': (d['A'] > d['B']).astype(float).to_numpy(), 'weights': {'A': 1}}], default={'C': 1})",
   jl = 'result = T.tactical_rules(d, [SL.RList("when" => Float64.(d.A .> d.B), "weights" => SL.named("A" => 1))], SL.named("C" => 1))')

# ── tactical_rules: Bedingungen als Text in R-Syntax (gemeinsamer Auswerter, Modul rexpr) ──
qpy <- function(x) paste0('"', gsub('"', '\\"', gsub("\n", "\\n", gsub("\\", "\\\\", x, fixed = TRUE), fixed = TRUE), fixed = TRUE), '"')
qjl <- function(x) paste0('"', gsub("$", "\\$", gsub('"', '\\"', gsub("\n", "\\n", gsub("\\", "\\\\", x, fixed = TRUE), fixed = TRUE), fixed = TRUE), fixed = TRUE), '"')
trx <- function(id, when, pre_r = "", pre_p = "", pre_j = "") {
  cs(id, sprintf("%sattr(tactical_rules(d, list(list(when = %s, weights = c(A = 1)), list(when = 'B > 100', weights = c(B = 1))), default = c(C = 1)), 'regime')",
                 pre_r, deparse(when)),
     sprintf("%sresult = T.tactical_rules(d, [{'when': %s, 'weights': {'A': 1}}, {'when': 'B > 100', 'weights': {'B': 1}}], default={'C': 1}).attrs['regime']",
             pre_p, qpy(when)),
     jl = sprintf('%sresult = SL.attrs(T.tactical_rules(d, [SL.RList("when" => %s, "weights" => SL.named("A" => 1)), SL.RList("when" => "B > 100", "weights" => SL.named("B" => 1))], SL.named("C" => 1); env = @__MODULE__))["regime"]',
                  pre_j, qjl(when)))
}
TRX <- c("!A > B", "A > B & !infl > 2.2", "infl %in% c(2, 2.05, 2.1)", "A > mean(A)", "A > quantile(A, 0.8)",
         "date >= as.Date('2013-06-01') & date < as.Date('2014-01-01')", "(A %/% 5) %% 2 == 0", "A > 105 & NA",
         "A > max(A) - 10 | B < min(B) + 2", "infl > c(2, 2.2)", "cumsum(A > 110) > 0", "abs(A - B) < 5",
         "sqrt(A) > 10.2", "log(A / B) > 0.05", "is.na(infl) | infl > 2.3", "\"TRUE\"", "ifelse(A > B, 1, 0)",
         "as.character(A > B)", "A > B\n& infl > 2", "A > ", "A >> B", "Z > 1", "A > B && infl > 2",
         "TRUE + (A > 100) == 2L", "A[-1] > A[-length(A)]", "{a <- A / B; a > 1.05}", "A > B # Kommentar",
         "date > \"2014-03-01\"", "infl == 2 | infl == 2.25", "!(A > B | B > C)")
for (k in seq_along(TRX)) trx(sprintf("tr_rx_%02d", k), TRX[[k]])
trx("tr_rx_env", "if (thr > 100) A > thr else B > thr", "thr <- 101; ", "thr = 101\n", "thr = 101; ")
trx("tr_rx_fun", "up(A) & !up(B)", "up <- function(x) x > 100; ", "def up(x):\n    return x > 100\n", "up(x) = x .> 100; ")
trx("tr_rx_fun2", "lag1(A) > A", "lag1 <- function(x) c(NA, x[-length(x)]); ",
    "def lag1(x):\n    return np.concatenate([[simlev._r.fmt.NA_REAL], np.asarray(x)[:-1]])\n", "lag1(x) = vcat(SL.NA, x[1:end-1]); ")

# ── tactical_rotation ────────────────────────────────────────────────────────
cs("rot_basic", "tactical_rotation(d, c('A', 'B'), top = 1, safe = c('C', 'CASH'))", "result = T.tactical_rotation(d, ['A', 'B'], top=1, safe=['C', 'CASH'])",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; top = 1, safe = ["C", "CASH"])')
cs("rot_attrs", "w <- tactical_rotation(d, c('A', 'B'), top = 1, safe = c('C', 'CASH')); list(attr(w, 'scores'), attr(w, 'decision_rows'))",
   "w = T.tactical_rotation(d, ['A', 'B'], top=1, safe=['C', 'CASH']); result = [w.attrs['scores'], w.attrs['decision_rows']]",
   jl = 'w = T.tactical_rotation(d, ["A", "B"]; top = 1, safe = ["C", "CASH"]); result = [SL.attrs(w)["scores"], SL.attrs(w)["decision_rows"]]')
cs("rot_canary", "tactical_rotation(d, c('A', 'B'), top = 2, safe = 'CASH', canary = c('A', 'B'), absolute = FALSE)",
   "result = T.tactical_rotation(d, ['A', 'B'], top=2, safe='CASH', canary=['A', 'B'], absolute=False)",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; top = 2, safe = "CASH", canary = ["A", "B"], absolute = false)')
cs("rot_breadth", "tactical_rotation(d, c('A', 'B', 'C'), top = 2, safe = 'CASH', canary = c('A', 'B', 'C'), breadth = 2, type = '13612w', every = 'quarter')",
   "result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2, safe='CASH', canary=['A', 'B', 'C'], breadth=2, type='13612w', every='quarter')",
   jl = 'result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2, safe = "CASH", canary = ["A", "B", "C"], breadth = 2, type = "13612w", every = "quarter")')
cs("rot_week", "tactical_rotation(d, c('A', 'B', 'C'), top = 2, safe = 'CASH', lookbacks = c(1, 3), every = 'week')",
   "result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2, safe='CASH', lookbacks=[1, 3], every='week')",
   jl = 'result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2, safe = "CASH", lookbacks = [1, 3], every = "week")')
cs("rot_invvol", "tactical_rotation(d, c('A', 'B', 'C'), top = 2, safe = 'CASH', weighting = 'inverse_vol', lookbacks = c(1, 6))",
   "result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2, safe='CASH', weighting='inverse_vol', lookbacks=[1, 6])",
   jl = 'result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2, safe = "CASH", weighting = "inverse_vol", lookbacks = [1, 6])')
cs("rot_nosafe", "tactical_rotation(d, c('B', 'A'), top = 1, absolute = FALSE, lookbacks = 3)",
   "result = T.tactical_rotation(d, ['B', 'A'], top=1, absolute=False, lookbacks=3)",
   jl = 'result = T.tactical_rotation(d, ["B", "A"]; top = 1, absolute = false, lookbacks = 3)')
cs("rot_na", "tactical_rotation(dna, c('A', 'B', 'C'), top = 3, safe = 'CASH', lookbacks = c(1, 2))",
   "result = T.tactical_rotation(dna, ['A', 'B', 'C'], top=3, safe='CASH', lookbacks=[1, 2])", inputs = list(dna = dna),
   jl = 'result = T.tactical_rotation(dna, ["A", "B", "C"]; top = 3, safe = "CASH", lookbacks = [1, 2])')
cs("rot_err_safe", "tactical_rotation(d, c('A', 'B'))", "result = T.tactical_rotation(d, ['A', 'B'])",
   jl = 'result = T.tactical_rotation(d, ["A", "B"])')
cs("rot_err_canary", "tactical_rotation(d, c('A', 'B'), absolute = FALSE, canary = 'C')", "result = T.tactical_rotation(d, ['A', 'B'], absolute=False, canary='C')",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; absolute = false, canary = "C")')
cs("rot_err_top", "tactical_rotation(d, c('A', 'B'), safe = 'CASH', top = 3)", "result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', top=3)",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", top = 3)')
cs("rot_err_top0", "tactical_rotation(d, c('A', 'B'), safe = 'CASH', top = 0)", "result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', top=0)",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", top = 0)')
cs("rot_err_breadth", "tactical_rotation(d, c('A', 'B'), safe = 'CASH', canary = 'A', breadth = 0)",
   "result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', canary='A', breadth=0)",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", canary = "A", breadth = 0)')
cs("rot_err_short", "tactical_rotation(d[1:300, ], c('A', 'B'), safe = 'CASH')", "result = T.tactical_rotation(d.iloc[:300], ['A', 'B'], safe='CASH')",
   jl = 'result = T.tactical_rotation(SL.rows(d, 1:300), ["A", "B"]; safe = "CASH")')
cs("rot_err_every", "tactical_rotation(d, c('A', 'B'), safe = 'CASH', every = 'year')", "result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', every='year')",
   jl = 'result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", every = "year")')

# ── tactical_target_volatility ────────────────────────────────────────────────────────
cs("tv_static", "tactical_target_volatility(d, c(A = 0.8, B = 0.2), safe = 'CASH', target = 8)",
   "result = T.tactical_target_volatility(d, {'A': 0.8, 'B': 0.2}, safe='CASH', target=8)",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 0.8, "B" => 0.2), "CASH"; target = 8)')
cs("tv_attrs", "w <- tactical_target_volatility(d, c(A = 1), safe = 'CASH', target = 5, every = 'week', window = 21); list(attr(w, 'exposure'), attr(w, 'volatility'))",
   "w = T.tactical_target_volatility(d, {'A': 1}, safe='CASH', target=5, every='week', window=21); result = [w.attrs['exposure'], w.attrs['volatility']]",
   jl = 'w = T.tactical_target_volatility(d, SL.named("A" => 1), "CASH"; target = 5, every = "week", window = 21); result = [SL.attrs(w)["exposure"], SL.attrs(w)["volatility"]]')
cs("tv_rot", "tactical_target_volatility(d, tactical_rotation(d, c('A', 'B'), safe = 'C'), safe = 'CASH', target = 6, every = 'day', max_exposure = 0.9)",
   "result = T.tactical_target_volatility(d, T.tactical_rotation(d, ['A', 'B'], safe='C'), safe='CASH', target=6, every='day', max_exposure=0.9)",
   jl = 'result = T.tactical_target_volatility(d, T.tactical_rotation(d, ["A", "B"]; safe = "C"), "CASH"; target = 6, every = "day", max_exposure = 0.9)')
cs("tv_ppy", "w <- tactical_target_volatility(wd2, c(A = 0.5, B = 0.5), safe = 'CASH', ppy = 252, every = 'quarter'); list(w, attr(w, 'exposure'))",
   "w = T.tactical_target_volatility(wd2, {'A': 0.5, 'B': 0.5}, safe='CASH', ppy=252, every='quarter'); result = [w, w.attrs['exposure']]",
   inputs = list(wd2 = d[!format(d$date, "%u") %in% c("6", "7"), ]),
   jl = 'w = T.tactical_target_volatility(wd2, SL.named("A" => 0.5, "B" => 0.5), "CASH"; ppy = 252, every = "quarter"); result = [w, SL.attrs(w)["exposure"]]')
cs("tv_safe_in_w", "tactical_target_volatility(d, c(A = 0.6, CASH = 0.4), safe = 'CASH', target = 20)",
   "result = T.tactical_target_volatility(d, pd.Series({'A': 0.6, 'CASH': 0.4}), safe='CASH', target=20)",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 0.6, "CASH" => 0.4), "CASH"; target = 20)')
cs("tv_warn", "tactical_target_volatility(d, c(A = 1), safe = 'CASH', target = 0.1)", "result = T.tactical_target_volatility(d, {'A': 1}, safe='CASH', target=0.1)",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 1), "CASH"; target = 0.1)')
cs("tv_err_kredit", "tactical_target_volatility(d, c(A = 1), safe = 'CASH', max_exposure = 2)", "result = T.tactical_target_volatility(d, {'A': 1}, safe='CASH', max_exposure=2)",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 1), "CASH"; max_exposure = 2)')
cs("tv_err_miss", "tactical_target_volatility(d, c(A = 1, gold = 0.5, x = 1), safe = 'CASH')", "result = T.tactical_target_volatility(d, {'A': 1, 'gold': 0.5, 'x': 1}, safe='CASH')",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 1, "gold" => 0.5, "x" => 1), "CASH")')
cs("tv_err_safe", "tactical_target_volatility(d, c(A = 1), safe = 'geld')", "result = T.tactical_target_volatility(d, {'A': 1}, safe='geld')",
   jl = 'result = T.tactical_target_volatility(d, SL.named("A" => 1), "geld")')
cs("tv_err_unnamed", "tactical_target_volatility(d, c(1, 2), safe = 'CASH')", "result = T.tactical_target_volatility(d, [1, 2], safe='CASH')",
   jl = 'result = T.tactical_target_volatility(d, [1, 2], "CASH")')
cs("tv_err_mismatch", "tactical_target_volatility(d, tactical_rules(d[1:100, ], list(), default = c(A = 1)), safe = 'CASH')",
   "result = T.tactical_target_volatility(d, T.tactical_rules(d.iloc[:100], [], default={'A': 1}), safe='CASH')",
   jl = 'result = T.tactical_target_volatility(d, T.tactical_rules(SL.rows(d, 1:100), [], SL.named("A" => 1)), "CASH")')
cs("tv_err_short", "tactical_target_volatility(d[1:50, ], c(A = 1), safe = 'CASH')", "result = T.tactical_target_volatility(d.iloc[:50], {'A': 1}, safe='CASH')",
   jl = 'result = T.tactical_target_volatility(SL.rows(d, 1:50), SL.named("A" => 1), "CASH")')

# ── tactical_conditional_volatility ───────────────────────────────────────────────────
cs("cv_basic", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.8, min_history = 1)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.8, min_history=1)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.8, min_history = 1)')
cs("cv_attrs", "w <- tactical_conditional_volatility(d, c(A = 0.7, B = 0.3), safe = 'CASH', base = 0.8, min_history = 1, every = 'week')
   list(attr(w, 'exposure'), attr(w, 'volatility'), attr(w, 'state'), attr(w, 'thresholds'))",
   "w = T.tactical_conditional_volatility(d, {'A': 0.7, 'B': 0.3}, safe='CASH', base=0.8, min_history=1, every='week')
result = [w.attrs['exposure'], w.attrs['volatility'], w.attrs['state'], w.attrs['thresholds']]",
   jl = 'w = T.tactical_conditional_volatility(d, SL.named("A" => 0.7, "B" => 0.3), "CASH"; base = 0.8, min_history = 1, every = "week")
result = [SL.attrs(w)["exposure"], SL.attrs(w)["volatility"], SL.attrs(w)["state"], SL.attrs(w)["thresholds"]]')
cs("cv_fixed", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.7, min_history = 1, scaling = 'fixed', high_exposure = 0.3, low_exposure = 0.9)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.7, min_history=1, scaling='fixed', high_exposure=0.3, low_exposure=0.9)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.7, min_history = 1, scaling = "fixed", high_exposure = 0.3, low_exposure = 0.9)')
cs("cv_fixed_nolow", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.7, min_history = 1, scaling = 'fixed', high_exposure = 0.2, lower = NULL)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.7, min_history=1, scaling='fixed', high_exposure=0.2, lower=None)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.7, min_history = 1, scaling = "fixed", high_exposure = 0.2, lower = nothing)')
cs("cv_msg", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', min_history = 1)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', min_history=1)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; min_history = 1)')
cs("cv_nolower", "w <- tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', lower = NULL, min_history = 1, upper = 0.7, target = 12, every = 'day'); list(w, attr(w, 'thresholds'), attr(w, 'state'))",
   "w = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', lower=None, min_history=1, upper=0.7, target=12, every='day'); result = [w, w.attrs['thresholds'], w.attrs['state']]",
   jl = 'w = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; lower = nothing, min_history = 1, upper = 0.7, target = 12, every = "day"); result = [w, SL.attrs(w)["thresholds"], SL.attrs(w)["state"]]')
cs("cv_target_warn", "tactical_conditional_volatility(d, c(B = 1), safe = 'C', base = 0.5, min_history = 1.5, target = 0.12, min_exposure = 0.2, max_exposure = 0.9, every = 'quarter')",
   "result = T.tactical_conditional_volatility(d, {'B': 1}, safe='C', base=0.5, min_history=1.5, target=0.12, min_exposure=0.2, max_exposure=0.9, every='quarter')",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("B" => 1), "C"; base = 0.5, min_history = 1.5, target = 0.12, min_exposure = 0.2, max_exposure = 0.9, every = "quarter")')
cs("cv_warn_hist", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.8, min_history = 10)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.8, min_history=10)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.8, min_history = 10)')
cs("cv_err_kredit", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', max_exposure = 1.5)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', max_exposure=1.5)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; max_exposure = 1.5)')
cs("cv_err_base", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 1.2, max_exposure = 1)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=1.2)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 1.2, max_exposure = 1)')
cs("cv_err_min", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, min_exposure = 0.6)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, min_exposure=0.6)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, min_exposure = 0.6)')
cs("cv_err_upper", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', upper = 1)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', upper=1)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; upper = 1)')
cs("cv_err_lower", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', lower = 0.9)", "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', lower=0.9)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; lower = 0.9)')
cs("cv_err_fixed", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', scaling = 'fixed', high_exposure = 0.3)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', scaling='fixed', high_exposure=0.3)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; scaling = "fixed", high_exposure = 0.3)')
cs("cv_err_high", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, scaling = 'fixed', high_exposure = 0.6, lower = NULL)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, scaling='fixed', high_exposure=0.6, lower=None)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, scaling = "fixed", high_exposure = 0.6, lower = nothing)')
cs("cv_err_low", "tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, scaling = 'fixed', high_exposure = 0.3, low_exposure = 0.4)",
   "result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, scaling='fixed', high_exposure=0.3, low_exposure=0.4)",
   jl = 'result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, scaling = "fixed", high_exposure = 0.3, low_exposure = 0.4)')
cs("cv_err_short", "tactical_conditional_volatility(d[1:40, ], c(A = 1), safe = 'CASH', base = 0.8)", "result = T.tactical_conditional_volatility(d.iloc[:40], {'A': 1}, safe='CASH', base=0.8)",
   jl = 'result = T.tactical_conditional_volatility(SL.rows(d, 1:40), SL.named("A" => 1), "CASH"; base = 0.8)')

# ── tactical_glidepath, tactical_blend ─────────────────────────────────────────────────
cs("gp_basic", "tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.3, C = 0.7))", "result = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.3, 'C': 0.7})",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.3, "C" => 0.7))')
cs("gp_dates", "tactical_glidepath(seq.Date(as.Date('2025-01-01'), as.Date('2030-12-31'), by = 'day'), from = c(aktien = 0.9, anleihen = 0.1),
                 to = c(anleihen = 0.6, geld = 0.4), start = '2026-03-01', end = as.Date('2029-06-30'), every = 'quarter')",
   "result = T.tactical_glidepath(np.arange(np.datetime64('2025-01-01'), np.datetime64('2031-01-01')), from_={'aktien': 0.9, 'anleihen': 0.1},
                    to={'anleihen': 0.6, 'geld': 0.4}, start='2026-03-01', end=np.datetime64('2029-06-30'), every='quarter')",
   jl = 'result = T.tactical_glidepath(collect(Date(2025, 1, 1):Day(1):Date(2030, 12, 31)), SL.named("aktien" => 0.9, "anleihen" => 0.1),
                    SL.named("anleihen" => 0.6, "geld" => 0.4); start = "2026-03-01", end_ = Date(2029, 6, 30), every = "quarter")')
cs("gp_month", "tactical_glidepath(d, from = c(A = 1), to = c(B = 1), every = 'month', start = '2011-01-01', end = '2014-01-01')",
   "result = T.tactical_glidepath(d, from_={'A': 1}, to={'B': 1}, every='month', start='2011-01-01', end='2014-01-01')",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 1), SL.named("B" => 1); every = "month", start = "2011-01-01", end_ = "2014-01-01")')
cs("gp_jump", "tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.4, C = 0.6), start = '2013-06-15', end = '2013-06-15')",
   "result = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.4, 'C': 0.6}, start='2013-06-15', end='2013-06-15')",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.4, "C" => 0.6); start = "2013-06-15", end_ = "2013-06-15")')
cs("gp_err", "tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.4, C = 0.6), start = '2014-01-01', end = '2013-01-01')",
   "result = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.4, 'C': 0.6}, start='2014-01-01', end='2013-01-01')",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.4, "C" => 0.6); start = "2014-01-01", end_ = "2013-01-01")')
cs("gp_err_date", "tactical_glidepath(d, from = c(A = 1), to = c(B = 1), start = '01.01.2013')", "result = T.tactical_glidepath(d, from_={'A': 1}, to={'B': 1}, start='01.01.2013')",
   jl = 'result = T.tactical_glidepath(d, SL.named("A" => 1), SL.named("B" => 1); start = "01.01.2013")')
cs("bl_basic", "gp <- tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.3, C = 0.7)); ro <- tactical_rotation(d, c('A', 'B'), top = 1, safe = c('C', 'CASH'))
   tactical_blend(x = gp, y = ro, shares = c(0.5, 0.5))",
   "gp = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.3, 'C': 0.7}); ro = T.tactical_rotation(d, ['A', 'B'], top=1, safe=['C', 'CASH'])
result = T.tactical_blend(gp, ro, shares=[0.5, 0.5])",
   jl = 'gp = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.3, "C" => 0.7)); ro = T.tactical_rotation(d, ["A", "B"]; top = 1, safe = ["C", "CASH"])
result = T.tactical_blend(gp, ro; shares = [0.5, 0.5])')
cs("bl_default", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), tactical_rules(d, list(list(when = 'A > B', weights = c(C = 1))), default = c(CASH = 1)))",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), T.tactical_rules(d, [{'when': 'A > B', 'weights': {'C': 1}}], default={'CASH': 1}))",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)), T.tactical_rules(d, [SL.RList("when" => "A > B", "weights" => SL.named("C" => 1))], SL.named("CASH" => 1)))')
cs("bl_shares", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), shares = c(3, 1))",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), shares=[3, 1])",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)); shares = [3, 1])')
cs("bl_err_shares", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), shares = 0.7)",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), shares=0.7)",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)); shares = 0.7)')
cs("bl_err_neg", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), shares = c(0.5, -0.25))",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), shares=[0.5, -0.25])",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)); shares = [0.5, -0.25])')
cs("bl_err_type", "tactical_blend(c(A = 1))", "result = T.tactical_blend({'A': 1})",
   jl = 'result = T.tactical_blend(SL.named("A" => 1))')
cs("bl_err_empty", "tactical_blend()", "result = T.tactical_blend()",
   jl = 'result = T.tactical_blend()')
cs("bl_err_dates", "tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d[1:10, ], list(), default = c(B = 1)))",
   "result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d.iloc[:10], [], default={'B': 1}))",
   jl = 'result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(SL.rows(d, 1:10), [], SL.named("B" => 1)))')

# ── interne Helfer ───────────────────────────────────────────────────────────
cs("helpers", "dd <- d$date[1:800]; list(SimLev:::.period_last(dd, 'day')[1:5], SimLev:::.period_last(dd, 'week'), SimLev:::.period_last(dd, 'month'),
                SimLev:::.period_last(dd, 'quarter'), SimLev:::.period_last(dd, 'year'),
                SimLev:::.hold_rows(10L, c(3L, 7L), matrix(1:6, 2, dimnames = list(NULL, c('x', 'y', 'z')))))",
   "dd = d['date'].to_numpy()[:800]; result = [T._period_last(dd, 'day')[:5], T._period_last(dd, 'week'), T._period_last(dd, 'month'),
          T._period_last(dd, 'quarter'), T._period_last(dd, 'year'),
          T._hold_rows(10, [3, 7], pd.DataFrame([[1., 3, 5], [2, 4, 6]], columns=['x', 'y', 'z']))]",
   jl = 'dd = d.date[1:800]; result = [T._period_last(dd, "day")[1:5], T._period_last(dd, "week"), T._period_last(dd, "month"),
          T._period_last(dd, "quarter"), T._period_last(dd, "year"),
          T._hold_rows(10, [3, 7], SL.NamedMat([1.0 3 5; 2 4 6]; colnames = ["x", "y", "z"]))]')
cs("helpers_err", "SimLev:::.period_last(d$date, 'decade')", "result = T._period_last(d['date'], 'decade')",
   jl = 'result = T._period_last(d.date, "decade")')
cs("as_weights_err", "SimLev:::.as_weights(d$date[1:3], matrix(c(1, 0, NA, 0, -1, 0), 3))", "result = T._as_weights(d['date'][:3], np.array([[1, 0], [0, -1], [simlev._r.fmt.NA_REAL, 0]]))",
   jl = 'result = T._as_weights(d.date[1:3], [1 0; 0 -1; SL.NA 0])')

# ── tactical_simulation ──────────────────────────────────────────────────────
ds <- make_mkt(365 * 3)[, c("date", "A", "C")]
set.seed(9); b2 <- runif(nrow(ds)) < 0.01; s2 <- runif(nrow(ds)) < 0.01
I3 <- list(ds = ds, b2 = b2, s2 = s2)
tsim <- function(id, r, py, inputs = I3, jl) cs(id, paste0(r, "; list(tactical = res$tactical, worth = res$worth, dates = res$dates)"),
                                            paste0(py, "\nresult = {'tactical': res.tactical, 'worth': res.worth, 'dates': res.dates}"), inputs = inputs,
                                            jl = paste0(jl, '\nresult = SL.RList("tactical" => res.tactical, "worth" => res.worth, "dates" => res.dates)'))
tsim("ts_rules", "wr <- tactical_rules(ds, list(list(when = list(buy = b2, sell = s2), weights = c(A = 1))), default = c(C = 1))
   res <- tactical_simulation(ds, wr, lag = 1, asset_args = list(spread = 0))",
   "wr = T.tactical_rules(ds, [{'when': {'buy': b2, 'sell': s2}, 'weights': {'A': 1}}], default={'C': 1})
res = T.tactical_simulation(ds, wr, lag=1, asset_args={'spread': 0})",
   jl = 'wr = T.tactical_rules(ds, [SL.RList("when" => SL.RList("buy" => b2, "sell" => s2), "weights" => SL.named("A" => 1))], SL.named("C" => 1))
res = T.tactical_simulation(ds, wr; lag = 1, asset_args = (spread = 0,))')
tsim("ts_year_lag0", "ws <- tactical_rules(ds, list(), default = c(A = 0.6, C = 0.4))
   res <- tactical_simulation(ds, ws, rebalance = 'year', lag = 0, asset_args = list(spread = 0))",
   "ws = T.tactical_rules(ds, [], default={'A': 0.6, 'C': 0.4})
res = T.tactical_simulation(ds, ws, rebalance='year', lag=0, asset_args={'spread': 0})",
   jl = 'ws = T.tactical_rules(ds, [], SL.named("A" => 0.6, "C" => 0.4))
res = T.tactical_simulation(ds, ws; rebalance = "year", lag = 0, asset_args = (spread = 0,))')
tsim("ts_tol", "ws <- tactical_glidepath(ds, from = c(A = 0.8, C = 0.2), to = c(A = 0.4, C = 0.6), every = 'quarter')
   res <- tactical_simulation(ds, ws, rebalance = 'month', tolerance = 5, lag = 2, asset_args = list(spread = 0.1, partial_exemption = c(A = 30, C = 0)))",
   "ws = T.tactical_glidepath(ds, from_={'A': 0.8, 'C': 0.2}, to={'A': 0.4, 'C': 0.6}, every='quarter')
res = T.tactical_simulation(ds, ws, rebalance='month', tolerance=5, lag=2, asset_args={'spread': 0.1, 'partial_exemption': pd.Series({'A': 30, 'C': 0})})",
   jl = 'ws = T.tactical_glidepath(ds, SL.named("A" => 0.8, "C" => 0.2), SL.named("A" => 0.4, "C" => 0.6); every = "quarter")
res = T.tactical_simulation(ds, ws; rebalance = "month", tolerance = 5, lag = 2, asset_args = (spread = 0.1, partial_exemption = SL.named("A" => 30, "C" => 0)))')
tsim("ts_rel_tax", "ws <- tactical_rules(ds, list(list(when = list(buy = b2, sell = s2), weights = c(A = 0.7, C = 0.3))), default = c(A = 0.2, C = 0.8))
   res <- tactical_simulation(ds, ws, rebalance = 'quarter', tolerance = 20, tolerance_type = 'relative', tax = tax_profile(), start_value = 50000, asset_args = list(spread = 0.1))",
   "ws = T.tactical_rules(ds, [{'when': {'buy': b2, 'sell': s2}, 'weights': {'A': 0.7, 'C': 0.3}}], default={'A': 0.2, 'C': 0.8})
res = T.tactical_simulation(ds, ws, rebalance='quarter', tolerance=20, tolerance_type='relative', tax=simlev.tax_profile(), start_value=50000, asset_args={'spread': 0.1})",
   jl = 'ws = T.tactical_rules(ds, [SL.RList("when" => SL.RList("buy" => b2, "sell" => s2), "weights" => SL.named("A" => 0.7, "C" => 0.3))], SL.named("A" => 0.2, "C" => 0.8))
res = T.tactical_simulation(ds, ws; rebalance = "quarter", tolerance = 20, tolerance_type = "relative", tax = SL.tax_profile(), start_value = 50000, asset_args = (spread = 0.1,))')
tsim("ts_dca", "ws <- tactical_rules(ds, list(list(when = list(buy = b2, sell = s2), weights = c(A = 1))), default = c(A = 0.3, C = 0.7))
   res <- tactical_simulation(ds, ws, dca = dca_plan(500, 1, unit = 'quarter'), asset_args = list(spread = 0.1))",
   "ws = T.tactical_rules(ds, [{'when': {'buy': b2, 'sell': s2}, 'weights': {'A': 1}}], default={'A': 0.3, 'C': 0.7})
res = T.tactical_simulation(ds, ws, dca=simlev.dca_plan(500, 1, unit='quarter'), asset_args={'spread': 0.1})",
   jl = 'ws = T.tactical_rules(ds, [SL.RList("when" => SL.RList("buy" => b2, "sell" => s2), "weights" => SL.named("A" => 1))], SL.named("A" => 0.3, "C" => 0.7))
res = T.tactical_simulation(ds, ws; dca = SL.dca_plan(500, 1; unit = "quarter"), asset_args = (spread = 0.1,))')
cal <- seq.Date(as.Date("2021-01-04"), as.Date("2021-03-31"), by = "day")
wkd <- cal[!format(cal, "%u") %in% c("6", "7")]
set.seed(11); al <- data.frame(date = cal, aktien = NA_real_, geld = 100)
al$aktien[match(wkd, cal)] <- 100 * cumprod(1 + rnorm(length(wkd), 0, 0.01))
fl <- cbind(aktien = is.na(al$aktien), geld = !cal %in% wkd)
al$aktien <- SimLev:::.fill_na(al$aktien, "locf")
I4 <- list(al = al, fl = fl)
tsim("ts_filled", "a2 <- al; attr(a2, 'filled') <- fl
   w <- tactical_rules(a2, list(list(when = a2$date >= as.Date('2021-02-05'), weights = c(aktien = 1))), default = c(geld = 1))
   res <- tactical_simulation(a2, w, lag = 1, asset_args = list(spread = 0))",
   "a2 = al.copy(); a2.attrs['filled'] = fl
w = T.tactical_rules(a2, [{'when': a2['date'] >= np.datetime64('2021-02-05'), 'weights': {'aktien': 1}}], default={'geld': 1})
res = T.tactical_simulation(a2, w, lag=1, asset_args={'spread': 0})", inputs = I4,
   jl = 'a2 = copy(al); SL.attrs(a2)["filled"] = fl
w = T.tactical_rules(a2, [SL.RList("when" => a2.date .>= Date(2021, 2, 5), "weights" => SL.named("aktien" => 1))], SL.named("geld" => 1))
res = T.tactical_simulation(a2, w; lag = 1, asset_args = (spread = 0,))')
tsim("ts_nofilled", "w <- tactical_rules(al, list(list(when = al$date >= as.Date('2021-02-05'), weights = c(aktien = 1))), default = c(geld = 1))
   res <- tactical_simulation(al, w, lag = 1, asset_args = list(spread = 0))",
   "w = T.tactical_rules(al, [{'when': al['date'] >= np.datetime64('2021-02-05'), 'weights': {'aktien': 1}}], default={'geld': 1})
res = T.tactical_simulation(al, w, lag=1, asset_args={'spread': 0})", inputs = I4,
   jl = 'w = T.tactical_rules(al, [SL.RList("when" => al.date .>= Date(2021, 2, 5), "weights" => SL.named("aktien" => 1))], SL.named("geld" => 1))
res = T.tactical_simulation(al, w; lag = 1, asset_args = (spread = 0,))')
tsim("ts_gaps", "ws <- tactical_rules(ds[seq(1, nrow(ds), 3), ], list(list(when = 'A > 101', weights = c(A = 1))), default = c(C = 1))
   res <- tactical_simulation(ds, ws, lag = 3, asset_args = list(spread = 0.1))",
   "ws = T.tactical_rules(ds.iloc[::3].reset_index(drop=True), [{'when': 'A > 101', 'weights': {'A': 1}}], default={'C': 1})
res = T.tactical_simulation(ds, ws, lag=3, asset_args={'spread': 0.1})",
   jl = 'ws = T.tactical_rules(SL.rows(ds, 1:3:SL.nrow(ds)), [SL.RList("when" => "A > 101", "weights" => SL.named("A" => 1))], SL.named("C" => 1))
res = T.tactical_simulation(ds, ws; lag = 3, asset_args = (spread = 0.1,))')
cs("ts_err_w", "tactical_simulation(ds, c(A = 1))", "result = T.tactical_simulation(ds, {'A': 1})", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, SL.named("A" => 1))')
cs("ts_err_flat", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), dca_mode = TRUE, dca_value = 100)",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), dca_mode=True, dca_value=100)", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); dca_mode = true, dca_value = 100)')
cs("ts_err_args", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), balance_mode = TRUE, event_col = 'x')",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), balance_mode=True, event_col='x')", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); balance_mode = true, event_col = "x")')
cs("ts_err_cols", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1, X = 1, Y = 1)))",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1, 'X': 1, 'Y': 1}))", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1, "X" => 1, "Y" => 1)))')
cs("ts_err_lag", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), lag = -1)",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), lag=-1)", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); lag = -1)')
cs("ts_err_lag2", "tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), lag = 'x')",
   "result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), lag='x')", inputs = I3,
   jl = 'result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); lag = "x")')
ref_done()
