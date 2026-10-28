# Referenzfälle für r/R/withdrawal.R und r/src/withdrawal_core.cpp
# (Python: simlev/withdrawal.py, simlev/_withdrawal_core.py).
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_withdrawal.R
source("golden/modules/ref_tools.R"); ref_init("withdrawal")

P <- "from simlev.bootstrap import *\nfrom simlev.withdrawal import *\nimport simlev.withdrawal as W\nimport simlev._withdrawal_core as WC\nimport simlev._r.rng as RNG\n"
JP <- "using SimLev.Bootstrap, SimLev.Withdrawal\nconst B = SimLev.Bootstrap\nconst W = SimLev.Withdrawal\nconst WC = SimLev.WithdrawalCore\nconst RNG = SimLev.RRng\n"
case <- function(id, r, py, inputs = list(), jl = NULL, ...) ref_case(id, r = r, py = paste0(P, py), inputs = inputs,
                                                                   jl = if (is.null(jl)) NULL else paste0(JP, jl), ...)
# Ergebnisse mit Rechenzeit: elapsed auf 0 setzen (beide Seiten)
wcase <- function(id, r, py, inputs = list(), jl = NULL, ...)
  case(id, paste0("ws <- ", r, "; ws$elapsed <- 0; ws"), paste0("ws = ", py, "; ws['elapsed'] = 0; result = ws"), inputs,
       jl = if (is.null(jl)) NULL else paste0("ws = ", jl, "; ws[\"elapsed\"] = 0; result = ws"), ...)

# ── Daten ───────────────────────────────────────────────────────────────────
set.seed(1); R <- matrix(exp(rnorm(30 * 12, 0.05, 0.15)), 30)
set.seed(2); Rm <- matrix(exp(rnorm(120 * 4, 0.05 / 12, 0.15 / sqrt(12))), 120)
set.seed(3); Rq <- matrix(exp(rnorm(42 * 3, 0.0125, 0.08)), 42)
set.seed(4); m <- data.frame(date = seq.Date(as.Date("1990-01-31") + 1, by = "month", length.out = 240) - 1)
m$depot <- 100 * cumprod(exp(rnorm(240, 0.005, 0.04))); m$cpi <- 100 * 1.02^((0:239) / 12)
m$infl <- 2 + sin((1:240) / 20); m$cape <- 15 + 10 * abs(sin((1:240) / 30)); m$br <- 1 + (1:240) / 100
set.seed(5); dd <- data.frame(date = seq.Date(as.Date("2001-01-01"), as.Date("2006-12-31"), by = "day"))
dd$px <- 100 * cumprod(1 + rnorm(nrow(dd), 2.5e-4, 0.01)); dd$cpi <- 100 * 1.02^(as.numeric(dd$date - dd$date[1]) / 365.25)
I <- list(R = R, Rm = Rm, Rq = Rq, m = m, dd = dd)

# ── withdrawal_rule ─────────────────────────────────────────────────────────
types <- c("constant", "percent", "vanguard", "guyton_klinger", "floor_ceiling", "clyatt", "ratchet", "endowment",
           "one_over_n", "vpw", "abw", "cape", "sensible", "hebeler")
for (t in types) case(paste0("rule_", t), sprintf("withdrawal_rule('%s')", t), sprintf("result = withdrawal_rule(type='%s')", t),
                     jl = sprintf('result = withdrawal_rule("%s")', t))
case("rule_default", "withdrawal_rule()", "result = withdrawal_rule()",
     jl = 'result = withdrawal_rule()')
case("rule_vg", "withdrawal_rule('vanguard', rate = 5, ceiling = 5, floor = 2.5)", "result = withdrawal_rule(type='vanguard', rate=5, ceiling=5, floor=2.5)",
     jl = 'result = withdrawal_rule("vanguard"; rate = 5, ceiling = 5, floor = 2.5)')
case("rule_gk", "withdrawal_rule('guyton_klinger', rate = 5.2, cpr_years = 12.7, inflation_cap = 3, skip_inflation = FALSE)",
     "result = withdrawal_rule(type='guyton_klinger', rate=5.2, cpr_years=12.7, inflation_cap=3, skip_inflation=False)",
     jl = 'result = withdrawal_rule("guyton_klinger"; rate = 5.2, cpr_years = 12.7, inflation_cap = 3, skip_inflation = false)')
case("rule_vpw_opts", "withdrawal_rule('vpw', stock_share = 50, age = 60.5, max_age = 95)", "result = withdrawal_rule(type='vpw', stock_share=50, age=60.5, max_age=95)",
     jl = 'result = withdrawal_rule("vpw"; stock_share = 50, age = 60.5, max_age = 95)')
case("rule_bounds", "withdrawal_rule('constant', min_real = 1e4, max_real = 5e4)", "result = withdrawal_rule(type='constant', min_real=1e4, max_real=5e4)",
     jl = 'result = withdrawal_rule("constant"; min_real = 1e4, max_real = 5e4)')
case("rule_bounds_min", "withdrawal_rule('percent', min_real = 2e4)", "result = withdrawal_rule(type='percent', min_real=2e4)",
     jl = 'result = withdrawal_rule("percent"; min_real = 2e4)')
case("rule_ratchet_opts", "withdrawal_rule('ratchet', raise = 5, ratchet_threshold = 1.25, ratchet_gap = 2)", "result = withdrawal_rule(type='ratchet', raise_=5, ratchet_threshold=1.25, ratchet_gap=2)",
     jl = 'result = withdrawal_rule("ratchet"; raise = 5, ratchet_threshold = 1.25, ratchet_gap = 2)')
case("rule_pfx", "withdrawal_rule('guy')", "result = withdrawal_rule(type='guy')",
     jl = 'result = withdrawal_rule("guy")')
case("rule_pv", "SimLev:::.wd_param_vector(withdrawal_rule('guyton_klinger', rate = 5, inflation_cap = 3, skip_inflation = FALSE))",
     "result = W._wd_param_vector(withdrawal_rule(type='guyton_klinger', rate=5, inflation_cap=3, skip_inflation=False))",
     jl = 'result = W._wd_param_vector(withdrawal_rule("guyton_klinger"; rate = 5, inflation_cap = 3, skip_inflation = false))')
case("rule_warn_rate", "withdrawal_rule('constant', rate = 0.04)", "result = withdrawal_rule(type='constant', rate=0.04)",
     jl = 'result = withdrawal_rule("constant"; rate = 0.04)')
case("rule_warn_frac", "withdrawal_rule('vanguard', ceiling = 0.05, floor = 0.025)", "result = withdrawal_rule(type='vanguard', ceiling=0.05, floor=0.025)",
     jl = 'result = withdrawal_rule("vanguard"; ceiling = 0.05, floor = 0.025)')
case("rule_warn_frac2", "withdrawal_rule('endowment', smoothing = 0.1, extra = 0.15, cut = 0)", "result = withdrawal_rule(type='endowment', smoothing=0.1, extra=0.15, cut=0)",
     jl = 'result = withdrawal_rule("endowment"; smoothing = 0.1, extra = 0.15, cut = 0)')
RE <- list(
  rate120 = c("withdrawal_rule('constant', rate = 120)", "withdrawal_rule(type='constant', rate=120)",
    'withdrawal_rule("constant"; rate = 120)'),
  ratevec = c("withdrawal_rule('constant', rate = c(4, 5))", "withdrawal_rule(type='constant', rate=[4, 5])",
    'withdrawal_rule("constant"; rate = [4, 5])'),
  ratena = c("withdrawal_rule('constant', rate = NA)", "withdrawal_rule(type='constant', rate=simlev._r.fmt.NA_REAL)",
    'withdrawal_rule("constant"; rate = SL.NA)'),
  ratechr = c("withdrawal_rule('constant', rate = '4')", "withdrawal_rule(type='constant', rate='4')",
    'withdrawal_rule("constant"; rate = "4")'),
  smooth = c("withdrawal_rule('endowment', smoothing = NA)", "withdrawal_rule(type='endowment', smoothing=simlev._r.fmt.NA_REAL)",
    'withdrawal_rule("endowment"; smoothing = SL.NA)'),
  vpwage = c("withdrawal_rule('vpw', age = 70, max_age = 65)", "withdrawal_rule(type='vpw', age=70, max_age=65)",
    'withdrawal_rule("vpw"; age = 70, max_age = 65)'),
  minmax = c("withdrawal_rule('constant', min_real = 5e4, max_real = 1e4)", "withdrawal_rule(type='constant', min_real=5e4, max_real=1e4)",
    'withdrawal_rule("constant"; min_real = 5e4, max_real = 1e4)'),
  floor95 = c("withdrawal_rule('clyatt', floor95 = 150)", "withdrawal_rule(type='clyatt', floor95=150)",
    'withdrawal_rule("clyatt"; floor95 = 150)'),
  cut = c("withdrawal_rule('guyton_klinger', cut = 150)", "withdrawal_rule(type='guyton_klinger', cut=150)",
    'withdrawal_rule("guyton_klinger"; cut = 150)'),
  icap = c("withdrawal_rule('guyton_klinger', inflation_cap = -5)", "withdrawal_rule(type='guyton_klinger', inflation_cap=-5)",
    'withdrawal_rule("guyton_klinger"; inflation_cap = -5)'),
  skip = c("withdrawal_rule('guyton_klinger', skip_inflation = 'ja')", "withdrawal_rule(type='guyton_klinger', skip_inflation='ja')",
    'withdrawal_rule("guyton_klinger"; skip_inflation = "ja")'),
  skipna = c("withdrawal_rule('guyton_klinger', skip_inflation = c(TRUE, FALSE))", "withdrawal_rule(type='guyton_klinger', skip_inflation=[True, False])",
    'withdrawal_rule("guyton_klinger"; skip_inflation = [true, false])'),
  gap = c("withdrawal_rule('ratchet', ratchet_gap = -1)", "withdrawal_rule(type='ratchet', ratchet_gap=-1)",
    'withdrawal_rule("ratchet"; ratchet_gap = -1)'),
  maxrate = c("withdrawal_rule('vpw', max_rate = 0)", "withdrawal_rule(type='vpw', max_rate=0)",
    'withdrawal_rule("vpw"; max_rate = 0)'),
  floor = c("withdrawal_rule('vanguard', floor = 120)", "withdrawal_rule(type='vanguard', floor=120)",
    'withdrawal_rule("vanguard"; floor = 120)'),
  ceil = c("withdrawal_rule('vanguard', ceiling = Inf)", "withdrawal_rule(type='vanguard', ceiling=np.inf)",
    'withdrawal_rule("vanguard"; ceiling = Inf)'),
  fv = c("withdrawal_rule('abw', fv = -1)", "withdrawal_rule(type='abw', fv=-1)",
    'withdrawal_rule("abw"; fv = -1)'),
  expret = c("withdrawal_rule('abw', exp_return = -100)", "withdrawal_rule(type='abw', exp_return=-100)",
    'withdrawal_rule("abw"; exp_return = -100)'),
  type = c("withdrawal_rule('foo')", "withdrawal_rule(type='foo')",
    'withdrawal_rule("foo")'),
  unused = c("withdrawal_rule('one_over_n', horizon = 30)", "withdrawal_rule(type='one_over_n', horizon=30)",
    'withdrawal_rule("one_over_n"; horizon = 30)'),
  maxreal = c("withdrawal_rule('constant', max_real = -1)", "withdrawal_rule(type='constant', max_real=-1)",
    'withdrawal_rule("constant"; max_real = -1)'))
for (k in names(RE)) case(paste0("rule_err_", k), RE[[k]][1], paste0("result = ", RE[[k]][2]), jl = paste0("result = ", RE[[k]][3]))

# ── Hilfen ──────────────────────────────────────────────────────────────────
case("ppy", "c(SimLev:::.wd_ppy('year'), SimLev:::.wd_ppy('quarter'), SimLev:::.wd_ppy('month'))", "result = [W._wd_ppy('year'), W._wd_ppy('quarter'), W._wd_ppy('month')]",
     jl = 'result = [W._wd_ppy("year"), W._wd_ppy("quarter"), W._wd_ppy("month")]')
case("ppy_err", "SimLev:::.wd_ppy('week')", "result = W._wd_ppy('week')",
     jl = 'result = W._wd_ppy("week")')
dts1 <- c("2000-01-31", "2000-01-15", "2000-02-29", "2001-03-31")
for (s in dts1) for (f in c("year", "quarter", "month")) {
  case(sprintf("anniv_%s_%s", gsub("-", "", s), f), sprintf("x <- seq.Date(as.Date('%s'), by = 'day', length.out = 800); SimLev:::.anniv_ends(x, '%s')", s, f),
       sprintf("x = np.datetime64('%s') + np.arange(800); result = W._anniv_ends(x, '%s')", s, f),
       jl = sprintf('x = Date("%s") .+ Day.(0:799); result = W._anniv_ends(x, "%s")', s, f))
}
case("anniv_td", "x <- seq.Date(as.Date('2001-01-01'), by = 'day', length.out = 1500); x <- x[!format(x, '%u') %in% c('6', '7')]; SimLev:::.anniv_ends(x, 'year')",
     "x = np.datetime64('2001-01-01') + np.arange(1500); wd = (x.astype('datetime64[D]').astype(int) + 3) % 7; x = x[wd < 5]; result = W._anniv_ends(x, 'year')",
     jl = 'x = Date(2001, 1, 1) .+ Day.(0:1499); x = x[Dates.dayofweek.(x) .< 6]; result = W._anniv_ends(x, "year")')
case("period_ends", "x <- seq.Date(as.Date('2000-12-20'), by = 'day', length.out = 200); list(SimLev:::.period_ends(x, 'month'), SimLev:::.period_ends(x, 'quarter'), SimLev:::.period_ends(x, 'year'))",
     "x = np.datetime64('2000-12-20') + np.arange(200); result = [W._period_ends(x, 'month'), W._period_ends(x, 'quarter'), W._period_ends(x, 'year')]",
     jl = 'x = Date(2000, 12, 20) .+ Day.(0:199); result = [W._period_ends(x, "month"), W._period_ends(x, "quarter"), W._period_ends(x, "year")]')
case("annual_real", "list(SimLev:::.annual_real(list(returns = Rm, inflation = matrix(1.001, 120, 4), frequency = 'month')), SimLev:::.annual_real(list(returns = Rm[1:12, ], inflation = matrix(1, 12, 4), frequency = 'month')), SimLev:::.annual_real(list(returns = Rq[1:9, ], inflation = matrix(1.01, 9, 3), frequency = 'quarter')))",
     "result = [W._annual_real({'returns': Rm, 'inflation': np.full((120, 4), 1.001), 'frequency': 'month'}), W._annual_real({'returns': Rm[:12], 'inflation': np.ones((12, 4)), 'frequency': 'month'}), W._annual_real({'returns': Rq[:9], 'inflation': np.full((9, 3), 1.01), 'frequency': 'quarter'})]", I,
     jl = 'result = [W._annual_real((returns = Rm, inflation = fill(1.001, 120, 4), frequency = "month")), W._annual_real((returns = Rm[1:12, :], inflation = ones(12, 4), frequency = "month")), W._annual_real((returns = Rq[1:9, :], inflation = fill(1.01, 9, 3), frequency = "quarter"))]')

# ── withdrawal_cohorts ─────────────────────────────────────────────────────
case("coh_basic", "withdrawal_cohorts(m, price = 'depot', inflation = 2, years = 5, step = 'year')", "result = withdrawal_cohorts(m, price='depot', inflation=2, years=5, step='year')", I,
     jl = 'result = withdrawal_cohorts(m; price = "depot", inflation = 2, years = 5, step = "year")')
case("coh_month", "withdrawal_cohorts(m[1:120, ], price = 'depot', years = 8)", "result = withdrawal_cohorts(m.iloc[:120], price='depot', years=8)", I,
     jl = 'result = withdrawal_cohorts(SL.rows(m, 1:120); price = "depot", years = 8)')
case("coh_cpi", "withdrawal_cohorts(m, price = 'depot', inflation = 'cpi', years = 10, step = 'year', frequency = 'quarter')",
     "result = withdrawal_cohorts(m, price='depot', inflation='cpi', years=10, step='year', frequency='quarter')", I,
     jl = 'result = withdrawal_cohorts(m; price = "depot", inflation = "cpi", years = 10, step = "year", frequency = "quarter")')
case("coh_rate", "withdrawal_cohorts(m, price = 'depot', inflation = 'infl', inflation_type = 'rate_pa', years = 2.5, frequency = 'quarter', step = 'year')",
     "result = withdrawal_cohorts(m, price='depot', inflation='infl', inflation_type='rate_pa', years=2.5, frequency='quarter', step='year')", I,
     jl = 'result = withdrawal_cohorts(m; price = "depot", inflation = "infl", inflation_type = "rate_pa", years = 2.5, frequency = "quarter", step = "year")')
case("coh_monthly_freq", "withdrawal_cohorts(m[1:60, ], price = 'depot', inflation = 'infl', inflation_type = 'rate', years = 1, frequency = 'month', step = 'year')",
     "result = withdrawal_cohorts(m.iloc[:60], price='depot', inflation='infl', inflation_type='rate', years=1, frequency='month', step='year')", I,
     jl = 'result = withdrawal_cohorts(SL.rows(m, 1:60); price = "depot", inflation = "infl", inflation_type = "rate", years = 1, frequency = "month", step = "year")')
case("coh_wrap", "withdrawal_cohorts(m[1:60, ], price = 'depot', inflation = 1.5, years = 3, step = 'year', wrap = TRUE, cape = 'cape', base_rate = 'br')",
     "result = withdrawal_cohorts(m.iloc[:60], price='depot', inflation=1.5, years=3, step='year', wrap=True, cape='cape', base_rate='br')", I,
     jl = 'result = withdrawal_cohorts(SL.rows(m, 1:60); price = "depot", inflation = 1.5, years = 3, step = "year", wrap = true, cape = "cape", base_rate = "br")')
case("coh_capeq", "withdrawal_cohorts(m, price = 'depot', years = 4, step = 'year', frequency = 'quarter', cape = 'cape', base_rate = 'br')",
     "result = withdrawal_cohorts(m, price='depot', years=4, step='year', frequency='quarter', cape='cape', base_rate='br')", I,
     jl = 'result = withdrawal_cohorts(m; price = "depot", years = 4, step = "year", frequency = "quarter", cape = "cape", base_rate = "br")')
case("coh_daily", "withdrawal_cohorts(dd, price = 'px', inflation = 'cpi', years = 2, step = 'year')", "result = withdrawal_cohorts(dd, price='px', inflation='cpi', years=2, step='year')", I,
     jl = 'result = withdrawal_cohorts(dd; price = "px", inflation = "cpi", years = 2, step = "year")')
case("coh_daily_rate", "x <- dd; x$r <- 2 + (seq_len(nrow(x)) %% 7) / 3; x$px[100:105] <- NA; withdrawal_cohorts(x, price = 'px', inflation = 'r', inflation_type = 'rate_pa', years = 1, frequency = 'month', step = 'year')",
     "x = dd.copy(); x['r'] = 2 + (np.arange(1, len(x) + 1) % 7) / 3; x.loc[99:104, 'px'] = simlev._r.fmt.NA_REAL; result = withdrawal_cohorts(x, price='px', inflation='r', inflation_type='rate_pa', years=1, frequency='month', step='year')", I,
     jl = 'x = copy(dd); x["r"] = 2 .+ ((1:SL.nrow(x)) .% 7) ./ 3; x.px[100:105] .= SL.NA; result = withdrawal_cohorts(x; price = "px", inflation = "r", inflation_type = "rate_pa", years = 1, frequency = "month", step = "year")')
case("coh_unsorted", "withdrawal_cohorts(m[c(240:1), ], price = 'depot', years = 15, step = 'year')", "result = withdrawal_cohorts(m.iloc[::-1], price='depot', years=15, step='year')", I,
     jl = 'result = withdrawal_cohorts(SL.rows(m, 240:-1:1); price = "depot", years = 15, step = "year")')
case("coh_chrdate", "x <- m[1:36, ]; x$date <- format(x$date); withdrawal_cohorts(x, price = 'depot', years = 1, step = 'year')",
     "x = m.iloc[:36].copy(); x['date'] = x['date'].dt.strftime('%Y-%m-%d'); result = withdrawal_cohorts(x, price='depot', years=1, step='year')", I,
     jl = 'x = SL.rows(m, 1:36); x["date"] = string.(x.date); result = withdrawal_cohorts(x; price = "depot", years = 1, step = "year")')
CE <- list(
  cols = c("withdrawal_cohorts(m, price = 'x')", "withdrawal_cohorts(m, price='x')",
    'withdrawal_cohorts(m; price = "x")'),
  gap = c("withdrawal_cohorts(m[-50, ], price = 'depot', years = 10, step = 'year')", "withdrawal_cohorts(m.drop(index=49), price='depot', years=10, step='year')",
    'withdrawal_cohorts(SL.rows(m, setdiff(1:240, 50)); price = "depot", years = 10, step = "year")'),
  annual = c("withdrawal_cohorts(m[seq(1, 240, 12), ], price = 'depot', years = 5)", "withdrawal_cohorts(m.iloc[::12], price='depot', years=5)",
    'withdrawal_cohorts(SL.rows(m, 1:12:240); price = "depot", years = 5)'),
  years = c("withdrawal_cohorts(m, price = 'depot', years = 2.5)", "withdrawal_cohorts(m, price='depot', years=2.5)",
    'withdrawal_cohorts(m; price = "depot", years = 2.5)'),
  years0 = c("withdrawal_cohorts(m, price = 'depot', years = 0)", "withdrawal_cohorts(m, price='depot', years=0)",
    'withdrawal_cohorts(m; price = "depot", years = 0)'),
  yearsvec = c("withdrawal_cohorts(m, price = 'depot', years = c(1, 2))", "withdrawal_cohorts(m, price='depot', years=[1, 2])",
    'withdrawal_cohorts(m; price = "depot", years = [1, 2])'),
  short = c("withdrawal_cohorts(m, price = 'depot', years = 30)", "withdrawal_cohorts(m, price='depot', years=30)",
    'withdrawal_cohorts(m; price = "depot", years = 30)'),
  ratebad = c("x <- m; x$infl[30] <- -150; withdrawal_cohorts(x, price = 'depot', inflation = 'infl', inflation_type = 'rate_pa', years = 1)",
              "x = m.copy(); x.loc[29, 'infl'] = -150; withdrawal_cohorts(x, price='depot', inflation='infl', inflation_type='rate_pa', years=1)",
    '(x = copy(m); x.infl[30] = -150; withdrawal_cohorts(x; price = "depot", inflation = "infl", inflation_type = "rate_pa", years = 1))'),
  freq = c("withdrawal_cohorts(m, price = 'depot', frequency = 'week')", "withdrawal_cohorts(m, price='depot', frequency='week')",
    'withdrawal_cohorts(m; price = "depot", frequency = "week")'))
for (k in names(CE)) case(paste0("coh_err_", k), CE[[k]][1], paste0("result = ", CE[[k]][2]), I, jl = paste0("result = ", CE[[k]][3]))

# ── withdrawal_perfect_rate ────────────────────────────────────────────────
case("pwr_mat", "withdrawal_perfect_rate(R)", "result = withdrawal_perfect_rate(R)", I,
     jl = 'result = withdrawal_perfect_rate(R)')
case("pwr_legacy", "withdrawal_perfect_rate(R[, 1:3], legacy = 0.5)", "result = withdrawal_perfect_rate(R[:, :3], legacy=0.5)", I,
     jl = 'result = withdrawal_perfect_rate(R[:, 1:3]; legacy = 0.5)')
case("pwr_vec", "withdrawal_perfect_rate(c(1.1, 0.8, 1.05, 1.2, 0.95))", "result = withdrawal_perfect_rate([1.1, 0.8, 1.05, 1.2, 0.95])",
     jl = 'result = withdrawal_perfect_rate([1.1, 0.8, 1.05, 1.2, 0.95])')
case("pwr_zero", "withdrawal_perfect_rate(c(1.05, 0, 1.1))", "result = withdrawal_perfect_rate([1.05, 0, 1.1])",
     jl = 'result = withdrawal_perfect_rate([1.05, 0, 1.1])')
case("pwr_wp", "withdrawal_perfect_rate(withdrawal_cohorts(m, price = 'depot', inflation = 'cpi', years = 3, step = 'year', frequency = 'month'))",
     "result = withdrawal_perfect_rate(withdrawal_cohorts(m, price='depot', inflation='cpi', years=3, step='year', frequency='month'))", I,
     jl = 'result = withdrawal_perfect_rate(withdrawal_cohorts(m; price = "depot", inflation = "cpi", years = 3, step = "year", frequency = "month"))')
case("pwr_wp1", "withdrawal_perfect_rate(withdrawal_cohorts(m, price = 'depot', years = 1, step = 'year', frequency = 'quarter'))",
     "result = withdrawal_perfect_rate(withdrawal_cohorts(m, price='depot', years=1, step='year', frequency='quarter'))", I,
     jl = 'result = withdrawal_perfect_rate(withdrawal_cohorts(m; price = "depot", years = 1, step = "year", frequency = "quarter"))')
PE <- list(med = c("withdrawal_perfect_rate(c(0.05, 0.02, -0.1))", "withdrawal_perfect_rate([0.05, 0.02, -0.1])",
    'withdrawal_perfect_rate([0.05, 0.02, -0.1])'),
           na = c("withdrawal_perfect_rate(c(1.05, NA))", "withdrawal_perfect_rate([1.05, simlev._r.fmt.NA_REAL])",
    'withdrawal_perfect_rate([1.05, SL.NA])'),
           neg = c("withdrawal_perfect_rate(c(1.05, 1.1, -0.2))", "withdrawal_perfect_rate([1.05, 1.1, -0.2])",
    'withdrawal_perfect_rate([1.05, 1.1, -0.2])'),
           leg = c("withdrawal_perfect_rate(c(1.05, 1.02), legacy = -1)", "withdrawal_perfect_rate([1.05, 1.02], legacy=-1)",
    'withdrawal_perfect_rate([1.05, 1.02]; legacy = -1)'),
           legv = c("withdrawal_perfect_rate(c(1.05, 1.02), legacy = c(1, 2))", "withdrawal_perfect_rate([1.05, 1.02], legacy=[1, 2])",
    'withdrawal_perfect_rate([1.05, 1.02]; legacy = [1, 2])'),
           inf = c("withdrawal_perfect_rate(c(1.05, Inf))", "withdrawal_perfect_rate([1.05, np.inf])",
    'withdrawal_perfect_rate([1.05, Inf])'))
for (k in names(PE)) case(paste0("pwr_err_", k), PE[[k]][1], paste0("result = ", PE[[k]][2]), jl = paste0("result = ", PE[[k]][3]))

# ── withdrawal_simulation: Regeln ──────────────────────────────────────────
for (t in setdiff(types, "cape")) wcase(paste0("ws_", t), sprintf("withdrawal_simulation(R, withdrawal_rule('%s'), inflation = 2, start_value = 5e5)", t),
                                        sprintf("withdrawal_simulation(R, rule=withdrawal_rule(type='%s'), inflation=2, start_value=5e5)", t), I,
                                        jl = sprintf('withdrawal_simulation(R, withdrawal_rule("%s"); inflation = 2, start_value = 5e5)', t))
wcase("ws_cape", "withdrawal_simulation(withdrawal_cohorts(m, price = 'depot', inflation = 'cpi', years = 10, step = 'year', cape = 'cape'), withdrawal_rule('cape'))",
      "withdrawal_simulation(withdrawal_cohorts(m, price='depot', inflation='cpi', years=10, step='year', cape='cape'), rule=withdrawal_rule(type='cape'))", I,
     jl = 'withdrawal_simulation(withdrawal_cohorts(m; price = "depot", inflation = "cpi", years = 10, step = "year", cape = "cape"), withdrawal_rule("cape"))')
wcase("ws_cape_month", "withdrawal_simulation(withdrawal_cohorts(m[1:120, ], price = 'depot', years = 4, step = 'year', frequency = 'month', cape = 'cape', base_rate = 'br'), withdrawal_rule('cape', cape_b = 1), tax = tax_profile())",
      "withdrawal_simulation(withdrawal_cohorts(m.iloc[:120], price='depot', years=4, step='year', frequency='month', cape='cape', base_rate='br'), rule=withdrawal_rule(type='cape', cape_b=1), tax=simlev.tax_profile())", I,
     jl = 'withdrawal_simulation(withdrawal_cohorts(SL.rows(m, 1:120); price = "depot", years = 4, step = "year", frequency = "month", cape = "cape", base_rate = "br"), withdrawal_rule("cape"; cape_b = 1); tax = SL.tax_profile())')
wcase("ws_gk_opts", "withdrawal_simulation(R, withdrawal_rule('guyton_klinger', rate = 6, inflation_cap = 2.5, cpr_years = 10), inflation = 3)",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='guyton_klinger', rate=6, inflation_cap=2.5, cpr_years=10), inflation=3)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("guyton_klinger"; rate = 6, inflation_cap = 2.5, cpr_years = 10); inflation = 3)')
wcase("ws_vpw_age", "withdrawal_simulation(R, withdrawal_rule('vpw', age = 80, max_age = 100, max_rate = 12), inflation = 2)",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='vpw', age=80, max_age=100, max_rate=12), inflation=2)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("vpw"; age = 80, max_age = 100, max_rate = 12); inflation = 2)')
wcase("ws_abw_fv", "withdrawal_simulation(R, withdrawal_rule('abw', exp_return = 0, fv = 2e5), inflation = 2)",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='abw', exp_return=0, fv=2e5), inflation=2)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("abw"; exp_return = 0, fv = 2e5); inflation = 2)')
wcase("ws_bounds", "withdrawal_simulation(R, withdrawal_rule('percent', rate = 6, min_real = 3e4, max_real = 5e4), inflation = 2)",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='percent', rate=6, min_real=3e4, max_real=5e4), inflation=2)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("percent"; rate = 6, min_real = 3e4, max_real = 5e4); inflation = 2)')
wcase("ws_ratchet_opts", "withdrawal_simulation(R, withdrawal_rule('ratchet', rate = 3, ratchet_threshold = 1.1, ratchet_gap = 0), inflation = 1)",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='ratchet', rate=3, ratchet_threshold=1.1, ratchet_gap=0), inflation=1)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("ratchet"; rate = 3, ratchet_threshold = 1.1, ratchet_gap = 0); inflation = 1)')
# Optionen
wcase("ws_end", "withdrawal_simulation(R, withdrawal_rule('constant', rate = 5), inflation = 2, timing = 'end')", "withdrawal_simulation(R, rule=withdrawal_rule(type='constant', rate=5), inflation=2, timing='end')", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("constant"; rate = 5); inflation = 2, timing = "end")')
wcase("ws_income", "withdrawal_simulation(R, withdrawal_rule('constant'), inflation = 2, income = list(list(start = 11, amount = 20000), list(start = 3.5, end = 8.2, amount = 5000), list(start = 25, end = 40, amount = 1e3)))",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='constant'), inflation=2, income=[{'start': 11, 'amount': 20000}, {'start': 3.5, 'end': 8.2, 'amount': 5000}, {'start': 25, 'end': 40, 'amount': 1e3}])", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("constant"); inflation = 2, income = [Dict("start" => 11, "amount" => 20000), Dict("start" => 3.5, "end" => 8.2, "amount" => 5000), Dict("start" => 25, "end" => 40, "amount" => 1e3)])')
wcase("ws_income1", "withdrawal_simulation(matrix(1, 10, 1), withdrawal_rule('constant', rate = 4), start_value = 1e6, income = list(start = 3, end = 5, amount = 10000))",
      "withdrawal_simulation(np.ones((10, 1)), rule=withdrawal_rule(type='constant', rate=4), start_value=1e6, income={'start': 3, 'end': 5, 'amount': 10000})",
     jl = 'withdrawal_simulation(ones(10, 1), withdrawal_rule("constant"; rate = 4); start_value = 1e6, income = Dict("start" => 3, "end" => 5, "amount" => 10000))')
wcase("ws_tax", "withdrawal_simulation(R[, 1:4], withdrawal_rule('guyton_klinger', rate = 5), start_value = 5e5, inflation = 2, tax = tax_profile(), cost_basis = 60, loss_carryforward = 3000, sale_cost = 0.1, base_rate = 2.5)",
      "withdrawal_simulation(R[:, :4], rule=withdrawal_rule(type='guyton_klinger', rate=5), start_value=5e5, inflation=2, tax=simlev.tax_profile(), cost_basis=60, loss_carryforward=3000, sale_cost=0.1, base_rate=2.5)", I,
     jl = 'withdrawal_simulation(R[:, 1:4], withdrawal_rule("guyton_klinger"; rate = 5); start_value = 5e5, inflation = 2, tax = SL.tax_profile(), cost_basis = 60, loss_carryforward = 3000, sale_cost = 0.1, base_rate = 2.5)')
wcase("ws_tax_novp", "withdrawal_simulation(R[, 1:4], withdrawal_rule('guyton_klinger', rate = 5), start_value = 5e5, inflation = 2, tax = tax_profile(), cost_basis = 60, loss_carryforward = 3000, sale_cost = 0.1, base_rate = 2.5, vorabpauschale = FALSE)",
      "withdrawal_simulation(R[:, :4], rule=withdrawal_rule(type='guyton_klinger', rate=5), start_value=5e5, inflation=2, tax=simlev.tax_profile(), cost_basis=60, loss_carryforward=3000, sale_cost=0.1, base_rate=2.5, vorabpauschale=False)", I,
     jl = 'withdrawal_simulation(R[:, 1:4], withdrawal_rule("guyton_klinger"; rate = 5); start_value = 5e5, inflation = 2, tax = SL.tax_profile(), cost_basis = 60, loss_carryforward = 3000, sale_cost = 0.1, base_rate = 2.5, vorabpauschale = false)')
wcase("ws_tax_flat", "withdrawal_simulation(matrix(1.10, 3, 1), withdrawal_rule('constant', rate = 4), start_value = 1e5, tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 3.2, cost_basis = 100)",
      "withdrawal_simulation(np.full((3, 1), 1.10), rule=withdrawal_rule(type='constant', rate=4), start_value=1e5, tax=simlev.tax_profile(sparer_pauschbetrag=0), base_rate=3.2, cost_basis=100)",
     jl = 'withdrawal_simulation(fill(1.10, 3, 1), withdrawal_rule("constant"; rate = 4); start_value = 1e5, tax = SL.tax_profile(; sparer_pauschbetrag = 0), base_rate = 3.2, cost_basis = 100)')
wcase("ws_tax_month", "withdrawal_simulation(Rm, withdrawal_rule('percent', rate = 5), frequency = 'month', tax = tax_profile(), base_rate = matrix(seq(0, 5, length.out = 480), 120, 4), cost_basis = 60, partial_exemption = 15, inflation = 1)",
      "withdrawal_simulation(Rm, rule=withdrawal_rule(type='percent', rate=5), frequency='month', tax=simlev.tax_profile(), base_rate=np.linspace(0, 5, 480).reshape((120, 4), order='F'), cost_basis=60, partial_exemption=15, inflation=1)", I,
     jl = 'withdrawal_simulation(Rm, withdrawal_rule("percent"; rate = 5); frequency = "month", tax = SL.tax_profile(), base_rate = reshape(vcat(0.0, [0.0 + i * (5 / 479) for i in 1:478], 5.0), 120, 4), cost_basis = 60, partial_exemption = 15, inflation = 1)')
wcase("ws_tax_end", "withdrawal_simulation(Rq, withdrawal_rule('vanguard', rate = 4.5), frequency = 'quarter', timing = 'end', tax = tax_profile(), cost_basis = 40, inflation = 2)",
      "withdrawal_simulation(Rq, rule=withdrawal_rule(type='vanguard', rate=4.5), frequency='quarter', timing='end', tax=simlev.tax_profile(), cost_basis=40, inflation=2)", I,
     jl = 'withdrawal_simulation(Rq, withdrawal_rule("vanguard"; rate = 4.5); frequency = "quarter", timing = "end", tax = SL.tax_profile(), cost_basis = 40, inflation = 2)')
wcase("ws_tax_1n", "withdrawal_simulation(R[, 1:3], withdrawal_rule('one_over_n'), tax = tax_profile(), cost_basis = 50, inflation = 2, sale_cost = 0.5)",
      "withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='one_over_n'), tax=simlev.tax_profile(), cost_basis=50, inflation=2, sale_cost=0.5)", I,
     jl = 'withdrawal_simulation(R[:, 1:3], withdrawal_rule("one_over_n"); tax = SL.tax_profile(), cost_basis = 50, inflation = 2, sale_cost = 0.5)')
wcase("ws_tax_hebeler", "withdrawal_simulation(Rm, withdrawal_rule('hebeler'), frequency = 'month', tax = tax_profile(), cost_basis = 70)",
      "withdrawal_simulation(Rm, rule=withdrawal_rule(type='hebeler'), frequency='month', tax=simlev.tax_profile(), cost_basis=70)", I,
     jl = 'withdrawal_simulation(Rm, withdrawal_rule("hebeler"); frequency = "month", tax = SL.tax_profile(), cost_basis = 70)')
wcase("ws_gamma1", "withdrawal_simulation(R, withdrawal_rule('percent'), inflation = 2, gamma = 1, keep_paths = FALSE)", "withdrawal_simulation(R, rule=withdrawal_rule(type='percent'), inflation=2, gamma=1, keep_paths=False)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("percent"); inflation = 2, gamma = 1, keep_paths = false)')
wcase("ws_gamma0", "withdrawal_simulation(R, withdrawal_rule('sensible'), inflation = 2, gamma = 0)", "withdrawal_simulation(R, rule=withdrawal_rule(type='sensible'), inflation=2, gamma=0)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("sensible"); inflation = 2, gamma = 0)')
wcase("ws_month", "withdrawal_simulation(Rm, withdrawal_rule('constant'), frequency = 'month', inflation = 2)", "withdrawal_simulation(Rm, rule=withdrawal_rule(type='constant'), frequency='month', inflation=2)", I,
     jl = 'withdrawal_simulation(Rm, withdrawal_rule("constant"); frequency = "month", inflation = 2)')
wcase("ws_quarter_trunc", "withdrawal_simulation(Rq, withdrawal_rule('endowment', rate = 4), frequency = 'quarter', inflation = 2)", "withdrawal_simulation(Rq, rule=withdrawal_rule(type='endowment', rate=4), frequency='quarter', inflation=2)", I,
     jl = 'withdrawal_simulation(Rq, withdrawal_rule("endowment"; rate = 4); frequency = "quarter", inflation = 2)')
wcase("ws_years", "withdrawal_simulation(R, withdrawal_rule('constant'), inflation = 2, years = 12)", "withdrawal_simulation(R, rule=withdrawal_rule(type='constant'), inflation=2, years=12)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("constant"); inflation = 2, years = 12)')
wcase("ws_years_q", "withdrawal_simulation(Rq, withdrawal_rule('constant'), frequency = 'quarter', years = 2.75, tax = tax_profile(), base_rate = matrix(2, 42, 3))",
      "withdrawal_simulation(Rq, rule=withdrawal_rule(type='constant'), frequency='quarter', years=2.75, tax=simlev.tax_profile(), base_rate=np.full((42, 3), 2.0))", I,
     jl = 'withdrawal_simulation(Rq, withdrawal_rule("constant"); frequency = "quarter", years = 2.75, tax = SL.tax_profile(), base_rate = fill(2.0, 42, 3))')
wcase("ws_infl_mat", "withdrawal_simulation(Rm[1:24, ], withdrawal_rule('clyatt'), frequency = 'month', inflation = matrix(1 + (1:96) / 1e4, 24, 4))",
      "withdrawal_simulation(Rm[:24], rule=withdrawal_rule(type='clyatt'), frequency='month', inflation=(1 + np.arange(1, 97) / 1e4).reshape((24, 4), order='F'))", I,
     jl = 'withdrawal_simulation(Rm[1:24, :], withdrawal_rule("clyatt"); frequency = "month", inflation = reshape(1 .+ (1:96) ./ 1e4, 24, 4))')
wcase("ws_infl_null", "withdrawal_simulation(R[, 1:2], withdrawal_rule('floor_ceiling'), inflation = NULL)", "withdrawal_simulation(R[:, :2], rule=withdrawal_rule(type='floor_ceiling'), inflation=None)", I,
     jl = 'withdrawal_simulation(R[:, 1:2], withdrawal_rule("floor_ceiling"); inflation = nothing)')
wcase("ws_vec", "withdrawal_simulation(R[, 1], withdrawal_rule('constant'), inflation = 2)", "withdrawal_simulation(R[:, 0], rule=withdrawal_rule(type='constant'), inflation=2)", I,
     jl = 'withdrawal_simulation(R[:, 1], withdrawal_rule("constant"); inflation = 2)')
wcase("ws_fail_all", "withdrawal_simulation(matrix(0.8, 10, 2), withdrawal_rule('constant', rate = 20))", "withdrawal_simulation(np.full((10, 2), 0.8), rule=withdrawal_rule(type='constant', rate=20))",
     jl = 'withdrawal_simulation(fill(0.8, 10, 2), withdrawal_rule("constant"; rate = 20))')
wcase("ws_cohorts", "withdrawal_simulation(withdrawal_cohorts(m, price = 'depot', inflation = 'cpi', years = 10, step = 'year'), withdrawal_rule('constant', rate = 5))",
      "withdrawal_simulation(withdrawal_cohorts(m, price='depot', inflation='cpi', years=10, step='year'), rule=withdrawal_rule(type='constant', rate=5))", I,
     jl = 'withdrawal_simulation(withdrawal_cohorts(m; price = "depot", inflation = "cpi", years = 10, step = "year"), withdrawal_rule("constant"; rate = 5))')
wcase("ws_wp_weights", "wp <- structure(list(returns = R[, 1:5], inflation = matrix(1.02, 30, 5), cape = NULL, base_rate = NULL, frequency = 'year', historical = FALSE, start_dates = NULL, weights = c(1, 2, 0.5, 1, 1.5), source = 'x'), class = 'withdrawal_paths'); withdrawal_simulation(wp, withdrawal_rule('vanguard'))",
      "wp = W.WithdrawalPaths([('returns', R[:, :5]), ('inflation', np.full((30, 5), 1.02)), ('cape', None), ('base_rate', None), ('frequency', 'year'), ('historical', False), ('start_dates', None), ('weights', np.array([1, 2, 0.5, 1, 1.5])), ('source', 'x')]); withdrawal_simulation(wp, rule=withdrawal_rule(type='vanguard'))", I,
     jl = 'SL.RList("returns" => R[:, 1:5], "inflation" => fill(1.02, 30, 5), "cape" => nothing, "base_rate" => nothing, "frequency" => "year", "historical" => false, "start_dates" => nothing, "weights" => [1, 2, 0.5, 1, 1.5], "source" => "x"; class = "withdrawal_paths"); withdrawal_simulation(ws, withdrawal_rule("vanguard"))')
wcase("ws_short_month", "withdrawal_simulation(Rm[1:7, ], withdrawal_rule('constant'), frequency = 'month')", "withdrawal_simulation(Rm[:7], rule=withdrawal_rule(type='constant'), frequency='month')", I,
     jl = 'withdrawal_simulation(Rm[1:7, :], withdrawal_rule("constant"); frequency = "month")')
wcase("ws_month1", "withdrawal_simulation(Rm[1:12, ], withdrawal_rule('percent'), frequency = 'month', inflation = 2)", "withdrawal_simulation(Rm[:12], rule=withdrawal_rule(type='percent'), frequency='month', inflation=2)", I,
     jl = 'withdrawal_simulation(Rm[1:12, :], withdrawal_rule("percent"); frequency = "month", inflation = 2)')
wcase("ws_month_trunc", "withdrawal_simulation(Rm[1:30, ], withdrawal_rule('percent'), frequency = 'month', inflation = 2)", "withdrawal_simulation(Rm[:30], rule=withdrawal_rule(type='percent'), frequency='month', inflation=2)", I,
     jl = 'withdrawal_simulation(Rm[1:30, :], withdrawal_rule("percent"); frequency = "month", inflation = 2)')
# Horizonte
wcase("ws_hz_fixed", "withdrawal_simulation(R, withdrawal_rule('hebeler'), horizon = 20)", "withdrawal_simulation(R, rule=withdrawal_rule(type='hebeler'), horizon=20)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("hebeler"); horizon = 20)')
wcase("ws_hz_disc", "withdrawal_simulation(R, withdrawal_rule('constant', rate = 5), inflation = 2, horizon = withdrawal_horizon('discrete', years = c(10, 20, 35), prob = c(1, 2, 1)), tax = tax_profile(), cost_basis = 60)",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='constant', rate=5), inflation=2, horizon=withdrawal_horizon(type='discrete', years=[10, 20, 35], prob=[1, 2, 1]), tax=simlev.tax_profile(), cost_basis=60)", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("constant"; rate = 5); inflation = 2, horizon = withdrawal_horizon("discrete"; years = [10, 20, 35], prob = [1, 2, 1]), tax = SL.tax_profile(), cost_basis = 60)')
wcase("ws_hz_month", "withdrawal_simulation(Rm, withdrawal_rule('percent', rate = 5), frequency = 'month', tax = tax_profile(), base_rate = 2.5, cost_basis = 60, horizon = withdrawal_horizon('uniform', min = 3, max = 9), keep_paths = FALSE)",
      "withdrawal_simulation(Rm, rule=withdrawal_rule(type='percent', rate=5), frequency='month', tax=simlev.tax_profile(), base_rate=2.5, cost_basis=60, horizon=withdrawal_horizon(type='uniform', min=3, max=9), keep_paths=False)", I,
     jl = 'withdrawal_simulation(Rm, withdrawal_rule("percent"; rate = 5); frequency = "month", tax = SL.tax_profile(), base_rate = 2.5, cost_basis = 60, horizon = withdrawal_horizon("uniform"; min = 3, max = 9), keep_paths = false)')
wcase("ws_hz_normal", "withdrawal_simulation(R, withdrawal_rule('guyton_klinger'), inflation = 2, horizon = withdrawal_horizon('normal', mean = 25, sd = 5, min = 15, max = 40, seed = 3))",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='guyton_klinger'), inflation=2, horizon=withdrawal_horizon(type='normal', mean=25, sd=5, min=15, max=40, seed=3))", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("guyton_klinger"); inflation = 2, horizon = withdrawal_horizon("normal"; mean = 25, sd = 5, min = 15, max = 40, seed = 3))')
wcase("ws_hz_tri", "withdrawal_simulation(R, withdrawal_rule('constant'), inflation = 2, horizon = withdrawal_horizon('triangular', min = 5, mode = 20, max = 28))",
      "withdrawal_simulation(R, rule=withdrawal_rule(type='constant'), inflation=2, horizon=withdrawal_horizon(type='triangular', min=5, mode=20, max=28))", I,
     jl = 'withdrawal_simulation(R, withdrawal_rule("constant"); inflation = 2, horizon = withdrawal_horizon("triangular"; min = 5, mode = 20, max = 28))')
wcase("ws_hz_sample", "withdrawal_simulation(Rq, withdrawal_rule('constant'), frequency = 'quarter', horizon = withdrawal_horizon('sample', years = c(3, 5, 8)))",
      "withdrawal_simulation(Rq, rule=withdrawal_rule(type='constant'), frequency='quarter', horizon=withdrawal_horizon(type='sample', years=[3, 5, 8]))", I,
     jl = 'withdrawal_simulation(Rq, withdrawal_rule("constant"); frequency = "quarter", horizon = withdrawal_horizon("sample"; years = [3, 5, 8]))')
# Fehler und Warnungen
WE <- list(
  rule = c("withdrawal_simulation(R, list())", "withdrawal_simulation(R, rule={})",
    'withdrawal_simulation(R, (;))'),
  taxcls = c("withdrawal_simulation(R, tax = 'person')", "withdrawal_simulation(R, tax='person')",
    'withdrawal_simulation(R; tax = "person")'),
  taxchurch = c("withdrawal_simulation(R, tax = tax_profile(church_tax = 9, guenstigerpruefung = TRUE))",
    "withdrawal_simulation(R, tax=simlev.tax_profile(church_tax=9, guenstigerpruefung=True))",
    'withdrawal_simulation(R; tax = SL.tax_profile(; church_tax = 9, guenstigerpruefung = true))'),
  taxinc = c("withdrawal_simulation(R, tax = tax_profile(base_rate = 2, income = income_rate(42), harvest = harvest_rule(), private_sale_threshold = 600))",
    "withdrawal_simulation(R, tax=simlev.tax_profile(base_rate=2, income=simlev.income_rate(42), harvest=simlev.harvest_rule(), private_sale_threshold=600))",
    'withdrawal_simulation(R; tax = SL.tax_profile(; base_rate = 2, income = SL.income_rate(42), harvest = SL.harvest_rule(), private_sale_threshold = 600))'),
  taxrate = c("withdrawal_simulation(R, tax = tax_profile(rate = -5))", "withdrawal_simulation(R, tax=simlev.tax_profile(rate=-5))",
    'withdrawal_simulation(R; tax = SL.tax_profile(; rate = -5))'),
  bonus = c("withdrawal_simulation(R, tax = tax_profile(), partial_exemption = 130)", "withdrawal_simulation(R, tax=simlev.tax_profile(), partial_exemption=130)",
    'withdrawal_simulation(R; tax = SL.tax_profile(), partial_exemption = 130)'),
  cb = c("withdrawal_simulation(R, tax = tax_profile(), cost_basis = -10)", "withdrawal_simulation(R, tax=simlev.tax_profile(), cost_basis=-10)",
    'withdrawal_simulation(R; tax = SL.tax_profile(), cost_basis = -10)'),
  spb = c("withdrawal_simulation(R, tax = tax_profile(sparer_pauschbetrag = c(1000, 2000)))", "withdrawal_simulation(R, tax=simlev.tax_profile(sparer_pauschbetrag=[1000, 2000]))",
    'withdrawal_simulation(R; tax = SL.tax_profile(; sparer_pauschbetrag = [1000, 2000]))'),
  lc = c("withdrawal_simulation(R, loss_carryforward = NA)", "withdrawal_simulation(R, loss_carryforward=simlev._r.fmt.NA_REAL)",
    'withdrawal_simulation(R; loss_carryforward = SL.NA)'),
  gamma = c("withdrawal_simulation(R, gamma = -1)", "withdrawal_simulation(R, gamma=-1)",
    'withdrawal_simulation(R; gamma = -1)'),
  sale = c("withdrawal_simulation(R, sale_cost = 100)", "withdrawal_simulation(R, sale_cost=100)",
    'withdrawal_simulation(R; sale_cost = 100)'),
  keep = c("withdrawal_simulation(R, keep_paths = NA)", "withdrawal_simulation(R, keep_paths=simlev._r.fmt.NA_REAL)",
    'withdrawal_simulation(R; keep_paths = SL.NA)'),
  vp = c("withdrawal_simulation(R, vorabpauschale = 'ja')", "withdrawal_simulation(R, vorabpauschale='ja')",
    'withdrawal_simulation(R; vorabpauschale = "ja")'),
  infl = c("withdrawal_simulation(R, inflation = -100)", "withdrawal_simulation(R, inflation=-100)",
    'withdrawal_simulation(R; inflation = -100)'),
  inflmat = c("withdrawal_simulation(R, inflation = matrix(1.02, 30, 1))", "withdrawal_simulation(R, inflation=np.full((30, 1), 1.02))",
    'withdrawal_simulation(R; inflation = fill(1.02, 30, 1))'),
  inflchr = c("withdrawal_simulation(R, inflation = 'cpi')", "withdrawal_simulation(R, inflation='cpi')",
    'withdrawal_simulation(R; inflation = "cpi")'),
  hz0 = c("withdrawal_simulation(R, horizon = 0)", "withdrawal_simulation(R, horizon=0)",
    'withdrawal_simulation(R; horizon = 0)'),
  hzvec = c("withdrawal_simulation(R, horizon = c(5, 6))", "withdrawal_simulation(R, horizon=[5, 6])",
    'withdrawal_simulation(R; horizon = [5, 6])'),
  years = c("withdrawal_simulation(R, years = -1)", "withdrawal_simulation(R, years=-1)",
    'withdrawal_simulation(R; years = -1)'),
  yearsq = c("withdrawal_simulation(Rq, frequency = 'quarter', years = 2.6)", "withdrawal_simulation(Rq, frequency='quarter', years=2.6)",
    'withdrawal_simulation(Rq; frequency = "quarter", years = 2.6)'),
  br = c("withdrawal_simulation(R, base_rate = 'x')", "withdrawal_simulation(R, base_rate='x')",
    'withdrawal_simulation(R; base_rate = "x")'),
  brmat = c("withdrawal_simulation(R, tax = tax_profile(), base_rate = matrix(2.5, 1, 1))", "withdrawal_simulation(R, tax=simlev.tax_profile(), base_rate=np.full((1, 1), 2.5))",
    'withdrawal_simulation(R; tax = SL.tax_profile(), base_rate = fill(2.5, 1, 1))'),
  income = c("withdrawal_simulation(R, income = list(list(start = 5, end = 3, amount = 10000)))", "withdrawal_simulation(R, income=[{'start': 5, 'end': 3, 'amount': 10000}])",
    'withdrawal_simulation(R; income = [Dict("start" => 5, "end" => 3, "amount" => 10000)])'),
  income2 = c("withdrawal_simulation(R, income = list(list(start = 5)))", "withdrawal_simulation(R, income=[{'start': 5}])",
    'withdrawal_simulation(R; income = [Dict("start" => 5)])'),
  sv = c("withdrawal_simulation(R, start_value = -800)", "withdrawal_simulation(R, start_value=-800)",
    'withdrawal_simulation(R; start_value = -800)'),
  svchr = c("withdrawal_simulation(R, start_value = '1e5')", "withdrawal_simulation(R, start_value='1e5')",
    'withdrawal_simulation(R; start_value = "1e5")'),
  svvec = c("withdrawal_simulation(R, start_value = c(1, 2))", "withdrawal_simulation(R, start_value=[1, 2])",
    'withdrawal_simulation(R; start_value = [1, 2])'),
  neg = c("withdrawal_simulation(R - 1)", "withdrawal_simulation(R - 1)",
    'withdrawal_simulation(R .- 1)'),
  cape = c("withdrawal_simulation(R, withdrawal_rule('cape'))", "withdrawal_simulation(R, rule=withdrawal_rule(type='cape'))",
    'withdrawal_simulation(R, withdrawal_rule("cape"))'),
  na = c("x <- R; x[3, 2] <- NA; withdrawal_simulation(x)", "x = R.copy(); x[2, 1] = simlev._r.fmt.NA_REAL; withdrawal_simulation(x)",
    '(x = copy(R); x[3, 2] = SL.NA; withdrawal_simulation(x))'),
  timing = c("withdrawal_simulation(R, timing = 'mid')", "withdrawal_simulation(R, timing='mid')",
    'withdrawal_simulation(R; timing = "mid")'),
  wpdim = c("withdrawal_simulation(structure(list(returns = R, inflation = matrix(1, 3, 3), frequency = 'year'), class = 'withdrawal_paths'))",
            "withdrawal_simulation(W.WithdrawalPaths([('returns', R), ('inflation', np.ones((3, 3))), ('frequency', 'year')]))",
    'withdrawal_simulation(SL.RList("returns" => R, "inflation" => ones(3, 3), "frequency" => "year"; class = "withdrawal_paths"))'),
  empty = c("withdrawal_simulation(structure(list(returns = matrix(1, 0, 2), inflation = matrix(1, 0, 2), frequency = 'year'), class = 'withdrawal_paths'))",
            "withdrawal_simulation(W.WithdrawalPaths([('returns', np.ones((0, 2))), ('inflation', np.ones((0, 2))), ('frequency', 'year')]))",
    'withdrawal_simulation(SL.RList("returns" => ones(0, 2), "inflation" => ones(0, 2), "frequency" => "year"; class = "withdrawal_paths"))'))
for (k in names(WE)) case(paste0("ws_err_", k), WE[[k]][1], paste0("result = ", WE[[k]][2]), I, jl = paste0("result = ", WE[[k]][3]))
WW <- list(
  taxrate = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(rate = 0.26375))", "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(rate=0.26375))",
    'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(; rate = 0.26375))'),
  bonus = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(), partial_exemption = 0.3, cost_basis = 0.5)", "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(), partial_exemption=0.3, cost_basis=0.5)",
    'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(), partial_exemption = 0.3, cost_basis = 0.5)'),
  infl = c("withdrawal_simulation(R[, 1:2], inflation = 0.02)", "withdrawal_simulation(R[:, :2], inflation=0.02)",
    'withdrawal_simulation(R[:, 1:2]; inflation = 0.02)'),
  br = c("withdrawal_simulation(R[, 1:2], tax = tax_profile(), base_rate = 0.032)", "withdrawal_simulation(R[:, :2], tax=simlev.tax_profile(), base_rate=0.032)",
    'withdrawal_simulation(R[:, 1:2]; tax = SL.tax_profile(), base_rate = 0.032)'),
  hz = c("withdrawal_simulation(R[1:10, 1:3], horizon = withdrawal_horizon('uniform', min = 8, max = 14))", "withdrawal_simulation(R[:10, :3], horizon=withdrawal_horizon(type='uniform', min=8, max=14))",
    'withdrawal_simulation(R[1:10, 1:3]; horizon = withdrawal_horizon("uniform"; min = 8, max = 14))'))
for (k in names(WW)) wcase(paste0("ws_warn_", k), WW[[k]][1], WW[[k]][2], I, jl = WW[[k]][3])
# summary / print
case("ws_summary", "summary(withdrawal_simulation(R, withdrawal_rule('guyton_klinger'), inflation = 2, tax = tax_profile()), probs = c(0.1, 0.5, 0.9))",
     "result = summary(withdrawal_simulation(R, rule=withdrawal_rule(type='guyton_klinger'), inflation=2, tax=simlev.tax_profile()), probs=[0.1, 0.5, 0.9])", I,
     jl = 'result = r_summary(withdrawal_simulation(R, withdrawal_rule("guyton_klinger"); inflation = 2, tax = SL.tax_profile()); probs = [0.1, 0.5, 0.9])')
case("ws_summary_hz", "summary(withdrawal_simulation(R, withdrawal_rule('constant', rate = 6), inflation = 2, horizon = withdrawal_horizon('discrete', years = c(5, 15, 25), prob = c(1, 1, 1))))",
     "result = summary(withdrawal_simulation(R, rule=withdrawal_rule(type='constant', rate=6), inflation=2, horizon=withdrawal_horizon(type='discrete', years=[5, 15, 25], prob=[1, 1, 1])))", I,
     jl = 'result = r_summary(withdrawal_simulation(R, withdrawal_rule("constant"; rate = 6); inflation = 2, horizon = withdrawal_horizon("discrete"; years = [5, 15, 25], prob = [1, 1, 1])))')
case("ws_summary_coh", "summary(withdrawal_simulation(withdrawal_cohorts(m, price = 'depot', inflation = 'cpi', years = 12, step = 'year'), withdrawal_rule('constant', rate = 7)))",
     "result = summary(withdrawal_simulation(withdrawal_cohorts(m, price='depot', inflation='cpi', years=12, step='year'), rule=withdrawal_rule(type='constant', rate=7)))", I,
     jl = 'result = r_summary(withdrawal_simulation(withdrawal_cohorts(m; price = "depot", inflation = "cpi", years = 12, step = "year"), withdrawal_rule("constant"; rate = 7)))')
case("ws_summary_month", "summary(withdrawal_simulation(Rm[1:30, ], withdrawal_rule('constant'), frequency = 'month'))",
     "result = summary(withdrawal_simulation(Rm[:30], rule=withdrawal_rule(type='constant'), frequency='month'))", I,
     jl = 'result = r_summary(withdrawal_simulation(Rm[1:30, :], withdrawal_rule("constant"); frequency = "month"))')

# ── withdrawal_max_rate ────────────────────────────────────────────────────
case("mr_basic", "r <- withdrawal_max_rate(R, success = 0.75, inflation = 2, tol = 0.01); list(as.numeric(r), attr(r, 'success'))",
     "r = withdrawal_max_rate(R, success=0.75, inflation=2, tol=0.01); result = [float(r), r.success]", I,
     jl = 'r = withdrawal_max_rate(R; success = 0.75, inflation = 2, tol = 0.01); result = [r[1], SL.attrs(r)["success"]]')
case("mr_gk", "r <- withdrawal_max_rate(R[, 1:6], withdrawal_rule('guyton_klinger'), success = 1, lower = 1, upper = 10, tol = 0.05, inflation = 2, tax = tax_profile()); list(as.numeric(r), attr(r, 'success'))",
     "r = withdrawal_max_rate(R[:, :6], rule=withdrawal_rule(type='guyton_klinger'), success=1, lower=1, upper=10, tol=0.05, inflation=2, tax=simlev.tax_profile()); result = [float(r), r.success]", I,
     jl = 'r = withdrawal_max_rate(R[:, 1:6], withdrawal_rule("guyton_klinger"); success = 1, lower = 1, upper = 10, tol = 0.05, inflation = 2, tax = SL.tax_profile()); result = [r[1], SL.attrs(r)["success"]]')
case("mr_na", "r <- withdrawal_max_rate(matrix(0.5, 10, 3), success = 0.9, lower = 15); list(as.numeric(r), attr(r, 'success'))",
     "r = withdrawal_max_rate(np.full((10, 3), 0.5), success=0.9, lower=15); result = [float(r), r.success]",
     jl = 'r = withdrawal_max_rate(fill(0.5, 10, 3); success = 0.9, lower = 15); result = [r[1], SL.attrs(r)["success"]]')
case("mr_upper", "r <- withdrawal_max_rate(matrix(1.5, 10, 3), success = 0.9); list(as.numeric(r), attr(r, 'success'))",
     "r = withdrawal_max_rate(np.full((10, 3), 1.5), success=0.9); result = [float(r), r.success]",
     jl = 'r = withdrawal_max_rate(fill(1.5, 10, 3); success = 0.9); result = [r[1], SL.attrs(r)["success"]]')
case("mr_warn_once", "r <- withdrawal_max_rate(R[, 1:4], success = 0.5, tol = 0.5, inflation = 0.02); as.numeric(r)",
     "r = withdrawal_max_rate(R[:, :4], success=0.5, tol=0.5, inflation=0.02); result = float(r)", I,
     jl = 'r = withdrawal_max_rate(R[:, 1:4]; success = 0.5, tol = 0.5, inflation = 0.02); result = r[1]')
ME <- list(succ95 = c("withdrawal_max_rate(R, success = 95)", "withdrawal_max_rate(R, success=95)",
    'withdrawal_max_rate(R; success = 95)'),
           succ0 = c("withdrawal_max_rate(R, success = 0)", "withdrawal_max_rate(R, success=0)",
    'withdrawal_max_rate(R; success = 0)'),
           succ200 = c("withdrawal_max_rate(R, success = 200)", "withdrawal_max_rate(R, success=200)",
    'withdrawal_max_rate(R; success = 200)'),
           lu = c("withdrawal_max_rate(R, lower = 10, upper = 2)", "withdrawal_max_rate(R, lower=10, upper=2)",
    'withdrawal_max_rate(R; lower = 10, upper = 2)'),
           up = c("withdrawal_max_rate(R, upper = 150)", "withdrawal_max_rate(R, upper=150)",
    'withdrawal_max_rate(R; upper = 150)'),
           tol = c("withdrawal_max_rate(R, tol = 0)", "withdrawal_max_rate(R, tol=0)",
    'withdrawal_max_rate(R; tol = 0)'),
           rule = c("withdrawal_max_rate(R, withdrawal_rule('vpw'))", "withdrawal_max_rate(R, rule=withdrawal_rule(type='vpw'))",
    'withdrawal_max_rate(R, withdrawal_rule("vpw"))'),
           rule2 = c("withdrawal_max_rate(R, 1)", "withdrawal_max_rate(R, rule=1)",
    'withdrawal_max_rate(R, 1)'))
for (k in names(ME)) case(paste0("mr_err_", k), ME[[k]][1], paste0("result = ", ME[[k]][2]), I, jl = paste0("result = ", ME[[k]][3]))

# ── withdrawal_horizon ──────────────────────────────────────────────────────────
HM <- list(fixed = c("withdrawal_horizon('fixed', years = 30)", "withdrawal_horizon(type='fixed', years=30)",
    'withdrawal_horizon("fixed"; years = 30)'),
           uniform = c("withdrawal_horizon('uniform', min = 20, max = 30)", "withdrawal_horizon(type='uniform', min=20, max=30)",
    'withdrawal_horizon("uniform"; min = 20, max = 30)'),
           uniform_frac = c("withdrawal_horizon('uniform', min = 2.5, max = 6)", "withdrawal_horizon(type='uniform', min=2.5, max=6)",
    'withdrawal_horizon("uniform"; min = 2.5, max = 6)'),
           discrete = c("withdrawal_horizon('discrete', years = c(25, 30, 35, 40), prob = c(0.3, 0.4, 0.2, 0.1))", "withdrawal_horizon(type='discrete', years=[25, 30, 35, 40], prob=[0.3, 0.4, 0.2, 0.1])",
    'withdrawal_horizon("discrete"; years = [25, 30, 35, 40], prob = [0.3, 0.4, 0.2, 0.1])'),
           discrete1 = c("withdrawal_horizon('discrete', years = 30, prob = 1)", "withdrawal_horizon(type='discrete', years=30, prob=1)",
    'withdrawal_horizon("discrete"; years = 30, prob = 1)'),
           normal = c("withdrawal_horizon('normal', mean = 25, sd = 6, min = 10, max = 35, seed = 7)", "withdrawal_horizon(type='normal', mean=25, sd=6, min=10, max=35, seed=7)",
    'withdrawal_horizon("normal"; mean = 25, sd = 6, min = 10, max = 35, seed = 7)'),
           tri = c("withdrawal_horizon('triangular', min = 10, mode = 25, max = 35)", "withdrawal_horizon(type='triangular', min=10, mode=25, max=35)",
    'withdrawal_horizon("triangular"; min = 10, mode = 25, max = 35)'),
           tri0 = c("withdrawal_horizon('triangular', min = 30, mode = 30, max = 30)", "withdrawal_horizon(type='triangular', min=30, mode=30, max=30)",
    'withdrawal_horizon("triangular"; min = 30, mode = 30, max = 30)'),
           sample = c("withdrawal_horizon('sample', years = c(3.7, 12, 30))", "withdrawal_horizon(type='sample', years=[3.7, 12, 30])",
    'withdrawal_horizon("sample"; years = [3.7, 12, 30])'),
           small = c("withdrawal_horizon('normal', mean = 1, sd = 3, min = 0.2, max = 3)", "withdrawal_horizon(type='normal', mean=1, sd=3, min=0.2, max=3)",
    'withdrawal_horizon("normal"; mean = 1, sd = 3, min = 0.2, max = 3)'))
for (k in names(HM)) case(paste0("hz_", k), HM[[k]][1], paste0("result = ", HM[[k]][2]), jl = paste0("result = ", HM[[k]][3]))
for (k in c("uniform", "discrete", "normal", "tri", "sample", "small")) case(paste0("hz_draw_", k), sprintf("SimLev:::.draw_horizon(%s, 300)", HM[[k]][1]), sprintf("result = W._draw_horizon(%s, 300)", HM[[k]][2]),
                                                                   jl = sprintf("result = W._draw_horizon(%s, 300)", HM[[k]][3]))
case("hz_draw_walker", "SimLev:::.draw_horizon(withdrawal_horizon('discrete', years = 1:250, prob = (1:250)^2), 50)",
     "result = W._draw_horizon(withdrawal_horizon(type='discrete', years=np.arange(1, 251), prob=np.arange(1, 251) ** 2.0), 50)",
     jl = 'result = W._draw_horizon(withdrawal_horizon("discrete"; years = 1:250, prob = Float64.(1:250) .* (1:250)), 50)')
case("hz_seed_null", "set.seed(9); a <- SimLev:::.draw_horizon(withdrawal_horizon('uniform', min = 1, max = 50, seed = NULL), 5); list(a, runif(1))",
     "RNG.set_seed(9); a = W._draw_horizon(withdrawal_horizon(type='uniform', min=1, max=50, seed=None), 5); result = [a, RNG.runif(1)]",
     jl = 'RNG.set_seed(9); a = W._draw_horizon(withdrawal_horizon("uniform"; min = 1, max = 50, seed = nothing), 5); result = [a, RNG.runif(1)]')
case("hz_keeps_state", "set.seed(9); a <- SimLev:::.draw_horizon(withdrawal_horizon('uniform', min = 1, max = 50), 5); list(a, runif(1))",
     "RNG.set_seed(9); a = W._draw_horizon(withdrawal_horizon(type='uniform', min=1, max=50), 5); result = [a, RNG.runif(1)]",
     jl = 'RNG.set_seed(9); a = W._draw_horizon(withdrawal_horizon("uniform"; min = 1, max = 50), 5); result = [a, RNG.runif(1)]')
HE <- list(miss = c("withdrawal_horizon('uniform', min = 3)", "withdrawal_horizon(type='uniform', min=3)",
    'withdrawal_horizon("uniform"; min = 3)'),
           y0 = c("withdrawal_horizon('fixed', years = 0)", "withdrawal_horizon(type='fixed', years=0)",
    'withdrawal_horizon("fixed"; years = 0)'),
           min0 = c("withdrawal_horizon('uniform', min = 0, max = 30)", "withdrawal_horizon(type='uniform', min=0, max=30)",
    'withdrawal_horizon("uniform"; min = 0, max = 30)'),
           disc_neg = c("withdrawal_horizon('discrete', years = c(20, -1), prob = c(1, 1))", "withdrawal_horizon(type='discrete', years=[20, -1], prob=[1, 1])",
    'withdrawal_horizon("discrete"; years = [20, -1], prob = [1, 1])'),
           disc_len = c("withdrawal_horizon('discrete', years = c(20, 30), prob = 1)", "withdrawal_horizon(type='discrete', years=[20, 30], prob=1)",
    'withdrawal_horizon("discrete"; years = [20, 30], prob = 1)'),
           disc_p = c("withdrawal_horizon('discrete', years = c(20, 30), prob = c(0, 0))", "withdrawal_horizon(type='discrete', years=[20, 30], prob=[0, 0])",
    'withdrawal_horizon("discrete"; years = [20, 30], prob = [0, 0])'),
           vec = c("withdrawal_horizon('fixed', years = c(20, 30))", "withdrawal_horizon(type='fixed', years=[20, 30])",
    'withdrawal_horizon("fixed"; years = [20, 30])'),
           inf = c("withdrawal_horizon('uniform', min = 1, max = Inf)", "withdrawal_horizon(type='uniform', min=1, max=np.inf)",
    'withdrawal_horizon("uniform"; min = 1, max = Inf)'),
           minmax = c("withdrawal_horizon('uniform', min = 30, max = 20)", "withdrawal_horizon(type='uniform', min=30, max=20)",
    'withdrawal_horizon("uniform"; min = 30, max = 20)'),
           mode = c("withdrawal_horizon('triangular', min = 20, mode = 50, max = 30)", "withdrawal_horizon(type='triangular', min=20, mode=50, max=30)",
    'withdrawal_horizon("triangular"; min = 20, mode = 50, max = 30)'),
           sd = c("withdrawal_horizon('normal', mean = 20, sd = -1, min = 1, max = 30)", "withdrawal_horizon(type='normal', mean=20, sd=-1, min=1, max=30)",
    'withdrawal_horizon("normal"; mean = 20, sd = -1, min = 1, max = 30)'),
           type = c("withdrawal_horizon('weibull')", "withdrawal_horizon(type='weibull')",
    'withdrawal_horizon("weibull")'),
           chr = c("withdrawal_horizon('fixed', years = 'x')", "withdrawal_horizon(type='fixed', years='x')",
    'withdrawal_horizon("fixed"; years = "x")'))
for (k in names(HE)) case(paste0("hz_err_", k), HE[[k]][1], paste0("result = ", HE[[k]][2]), jl = paste0("result = ", HE[[k]][3]))

# ── Kern direkt ────────────────────────────────────────────────────────────
case("core_err_infl", "SimLev:::.wd_simulate(R, matrix(1, 30, 1), matrix(0, 30, 0), matrix(2.5, 30, 12), 1L, 1L, SimLev:::.wd_param_vector(withdrawal_rule('constant')), TRUE, 1e6, rep(0, 30), FALSE, 0.26375, 0.3, 1000, TRUE, 0, 1, 0, TRUE)",
     "result = WC.wd_simulate(R, np.ones((30, 1)), np.zeros((30, 0)), np.full((30, 12), 2.5), 1, 1, W._wd_param_vector(withdrawal_rule(type='constant')), True, 1e6, np.zeros(30), False, 0.26375, 0.3, 1000, True, 0, 1, 0, True)", I,
     jl = 'result = WC.wd_simulate(R, ones(30, 1), zeros(30, 0), fill(2.5, 30, 12), 1, 1, W._wd_param_vector(withdrawal_rule("constant")), true, 1e6, zeros(30), false, 0.26375, 0.3, 1000, true, 0, 1, 0, true)')
case("core_lots", "SimLev:::.wd_simulate(R[, 1:3], matrix(1.02, 30, 3), matrix(0, 30, 0), matrix(2.5, 30, 3), 1L, 2L, SimLev:::.wd_param_vector(withdrawal_rule('percent', rate = 6)), TRUE, 1e5, rep(0, 30), TRUE, 0.26375, 0.3, 500, TRUE, 0.001, 0.8, 100, TRUE, c(2e4, 3e4, 4e4, 1e4), c(1.5e4, 3.1e4, 2e4, 1e4), c(10, 0, 50, 0), c(0L, 0L, 1L, 2L), 120, TRUE)",
     "result = WC.wd_simulate(R[:, :3], np.full((30, 3), 1.02), np.zeros((30, 0)), np.full((30, 3), 2.5), 1, 2, W._wd_param_vector(withdrawal_rule(type='percent', rate=6)), True, 1e5, np.zeros(30), True, 0.26375, 0.3, 500, True, 0.001, 0.8, 100, True, [2e4, 3e4, 4e4, 1e4], [1.5e4, 3.1e4, 2e4, 1e4], [10, 0, 50, 0], [0, 0, 1, 2], 120, True)", I,
     jl = 'result = WC.wd_simulate(R[:, 1:3], fill(1.02, 30, 3), zeros(30, 0), fill(2.5, 30, 3), 1, 2, W._wd_param_vector(withdrawal_rule("percent"; rate = 6)), true, 1e5, zeros(30), true, 0.26375, 0.3, 500, true, 0.001, 0.8, 100, true, [2e4, 3e4, 4e4, 1e4], [1.5e4, 3.1e4, 2e4, 1e4], [10, 0, 50, 0], [0, 0, 1, 2], 120, true)')
case("core_lots_loss", "SimLev:::.wd_simulate(matrix(c(0.7, 1.3, 0.9, 1.1, 1.2), 5, 1), matrix(1, 5, 1), matrix(0, 5, 0), matrix(3, 5, 1), 1L, 1L, SimLev:::.wd_param_vector(withdrawal_rule('constant', rate = 25)), FALSE, 1e5, rep(5000, 5), TRUE, 0.26375, 0.3, 1000, TRUE, 0.002, 0.9, 0, TRUE, c(5e4, 5e4), c(8e4, 2e4), c(0, 100), c(0L, 1L), -1, TRUE)",
     "result = WC.wd_simulate(np.array([[0.7], [1.3], [0.9], [1.1], [1.2]]), np.ones((5, 1)), np.zeros((5, 0)), np.full((5, 1), 3.0), 1, 1, W._wd_param_vector(withdrawal_rule(type='constant', rate=25)), False, 1e5, np.full(5, 5000.0), True, 0.26375, 0.3, 1000, True, 0.002, 0.9, 0, True, [5e4, 5e4], [8e4, 2e4], [0, 100], [0, 1], -1, True)",
     jl = 'result = WC.wd_simulate(reshape([0.7, 1.3, 0.9, 1.1, 1.2], 5, 1), ones(5, 1), zeros(5, 0), fill(3.0, 5, 1), 1, 1, W._wd_param_vector(withdrawal_rule("constant"; rate = 25)), false, 1e5, fill(5000.0, 5), true, 0.26375, 0.3, 1000, true, 0.002, 0.9, 0, true, [5e4, 5e4], [8e4, 2e4], [0, 100], [0, 1], -1, true)')
case("core_err_lots", "SimLev:::.wd_simulate(R, R, matrix(0, 30, 0), R, 1L, 1L, SimLev:::.wd_param_vector(withdrawal_rule('constant')), TRUE, 1e6, 0, TRUE, 0.26375, 0.3, 1000, TRUE, 0, 1, 0, TRUE, c(1, 0), c(1, 1), c(0, 0), c(0L, 1L))",
     "result = WC.wd_simulate(R, R, np.zeros((30, 0)), R, 1, 1, W._wd_param_vector(withdrawal_rule(type='constant')), True, 1e6, [0.0], True, 0.26375, 0.3, 1000, True, 0, 1, 0, True, [1, 0], [1, 1], [0, 0], [0, 1])", I,
     jl = 'result = WC.wd_simulate(R, R, zeros(30, 0), R, 1, 1, W._wd_param_vector(withdrawal_rule("constant")), true, 1e6, [0.0], true, 0.26375, 0.3, 1000, true, 0, 1, 0, true, [1, 0], [1, 1], [0, 0], [0, 1])')
case("core_err_group", "SimLev:::.wd_simulate(R, R, matrix(0, 30, 0), R, 1L, 1L, SimLev:::.wd_param_vector(withdrawal_rule('constant')), TRUE, 1e6, 0, TRUE, 0.26375, 0.3, 1000, TRUE, 0, 1, 0, TRUE, c(1, 2), c(1, 1), c(0, 0), c(1L, 0L))",
     "result = WC.wd_simulate(R, R, np.zeros((30, 0)), R, 1, 1, W._wd_param_vector(withdrawal_rule(type='constant')), True, 1e6, [0.0], True, 0.26375, 0.3, 1000, True, 0, 1, 0, True, [1, 2], [1, 1], [0, 0], [1, 0])", I,
     jl = 'result = WC.wd_simulate(R, R, zeros(30, 0), R, 1, 1, W._wd_param_vector(withdrawal_rule("constant")), true, 1e6, [0.0], true, 0.26375, 0.3, 1000, true, 0, 1, 0, true, [1, 2], [1, 1], [0, 0], [1, 0])')
case("fee_set", "c(SimLev:::.wd_fee_set(NULL), SimLev:::.wd_fee_set(1), SimLev:::.wd_fee_set(0), SimLev:::.wd_fee_set(list(fixed = 0, percent = 0, min = 0, max = Inf)), SimLev:::.wd_fee_set(list(fixed = 0, percent = 0.1)), SimLev:::.wd_fee_set('a'), SimLev:::.wd_fee_set(list(max = 5)))",
     "result = [W._wd_fee_set(None), W._wd_fee_set(1), W._wd_fee_set(0), W._wd_fee_set({'fixed': 0, 'percent': 0, 'min': 0, 'max': np.inf}), W._wd_fee_set({'fixed': 0, 'percent': 0.1}), W._wd_fee_set('a'), W._wd_fee_set({'max': 5})]",
     jl = 'result = [W._wd_fee_set(nothing), W._wd_fee_set(1), W._wd_fee_set(0), W._wd_fee_set((fixed = 0, percent = 0, min = 0, max = Inf)), W._wd_fee_set((fixed = 0, percent = 0.1)), W._wd_fee_set("a"), W._wd_fee_set((max = 5,))]')
case("wd_lots", "ol <- list(A = list(lots = data.frame(date = as.Date('2019-01-01') + 0:2, units = c(1, 2, 0), price = c(10, 12, 14), vp = c(0, 0.5, 0)), cash = 0), B = list(lots = data.frame(date = as.Date('2019-01-01'), units = 5e-14, price = 1, vp = 0), cash = 0), C = list(lots = data.frame(date = as.Date('2019-01-01'), units = 4, price = 5, vp = 0.1), cash = 2)); rep <- list(A = list(worth = c(1, 45)), B = list(worth = c(1, 0)), C = list(worth = c(3, 30))); list(SimLev:::.wd_held(ol, rep, 100), SimLev:::.wd_lots(ol, rep, 100))",
     "L = lambda **k: pd.DataFrame(k)\nol = {'A': {'lots': L(units=[1., 2, 0], price=[10., 12, 14], vp=[0, 0.5, 0]), 'cash': 0.0}, 'B': {'lots': L(units=[5e-14], price=[1.0], vp=[0.0]), 'cash': 0.0}, 'C': {'lots': L(units=[4.0], price=[5.0], vp=[0.1]), 'cash': 2.0}}\nrep = {'A': {'worth': np.array([1, 45.])}, 'B': {'worth': np.array([1, 0.])}, 'C': {'worth': np.array([3, 30.])}}\nresult = [W._wd_held(ol, rep, 100), W._wd_lots(ol, rep, 100)]",
     jl = 'L(; k...) = SL.RFrame((string(a) => b for (a, b) in k)...)
ol = (A = (lots = L(units = [1.0, 2, 0], price = [10.0, 12, 14], vp = [0, 0.5, 0]), cash = 0.0), B = (lots = L(units = [5e-14], price = [1.0], vp = [0.0]), cash = 0.0), C = (lots = L(units = [4.0], price = [5.0], vp = [0.1]), cash = 2.0))
rep = (A = (worth = [1, 45.0],), B = (worth = [1, 0.0],), C = (worth = [3, 30.0],))
result = [W._wd_held(ol, rep, 100), W._wd_lots(ol, rep, 100)]')

# ── simulation-basierte Teile ──────────────────────────────────────────────
set.seed(4); dsim <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "day", length.out = 1500))
dsim$ETF <- 100 * cumprod(1 + rnorm(1500, 3e-4, 0.01))
Is <- c(I, list(dsim = dsim))
SIM_R <- "st <- create_strategy(ETF = asset_config('etf', 'bnh', spread = 0))\nr1 <- simulation(dsim, st, start_value = 1000)\nr2 <- simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))\n"
SIM_J <- 'st = create_strategy(ETF = asset_config("etf", "bnh", spread = 0))
r1 = simulation(dsim, st; start_value = 1000)
r2 = simulation(dsim, st, start_value = 1000, dca = dca_plan(value = 500, span = 1))
'
SIM_P <- "st = simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0))\nr1 = simlev.simulation(dsim, st, start_value=1000)\nr2 = simlev.simulation(dsim, st, start_value=1000, dca=simlev.dca_plan(value=500, span=1))\n"
case("ri_basic", paste0(SIM_R, "list(result_index(r1), result_index(r2, base = 1))"), paste0(SIM_P, "result = [result_index(r1), result_index(r2, base=1)]"), Is,
     jl = paste0(SIM_J, 'result = [result_index(r1), result_index(r2; base = 1)]'))
case("ri_old", paste0(SIM_R, "r2$twr_index <- NULL; result_index(r2)"), paste0(SIM_P, "r2.twr_index = None; result = result_index(r2)"), Is,
     jl = paste0(SIM_J, 'delete!(r2.data, "twr_index"); result = result_index(r2)'))
case("ri_err", "result_index(list())", "result = result_index([])",
     jl = 'result = result_index((;))')
case("coh_result", paste0(SIM_R, "withdrawal_cohorts(r2, years = 2, step = 'year', inflation = 2)"), paste0(SIM_P, "result = withdrawal_cohorts(r2, years=2, step='year', inflation=2)"), Is,
     jl = paste0(SIM_J, 'result = withdrawal_cohorts(r2; years = 2, step = "year", inflation = 2)'))
case("coh_result_err", paste0(SIM_R, "withdrawal_cohorts(r2, years = 2, inflation = 'cpi')"), paste0(SIM_P, "result = withdrawal_cohorts(r2, years=2, inflation='cpi')"), Is,
     jl = paste0(SIM_J, 'result = withdrawal_cohorts(r2; years = 2, inflation = "cpi")'))
wcase("ws_result", paste0("{", SIM_R, "withdrawal_simulation(r1, withdrawal_rule('constant', rate = 4), years = 2, inflation = 2)}"),
      paste0("None\n", SIM_P, "ws = withdrawal_simulation(r1, rule=withdrawal_rule(type='constant', rate=4), years=2, inflation=2)"), Is,
     jl = paste0("nothing\n", SIM_J, 'ws = withdrawal_simulation(r1, withdrawal_rule("constant"; rate = 4); years = 2, inflation = 2)'))
case("ws_result_err", paste0(SIM_R, "withdrawal_simulation(r1, inflation = 'x')"), paste0(SIM_P, "result = withdrawal_simulation(r1, inflation='x')"), Is,
     jl = paste0(SIM_J, 'result = withdrawal_simulation(r1; inflation = "x")'))
case("wp_list", paste0(SIM_R, "withdrawal_paths(list(r1, r2), inflation = 2, frequency = 'quarter')"), paste0(SIM_P, "result = withdrawal_paths([r1, r2], inflation=2, frequency='quarter')"), Is,
     jl = paste0(SIM_J, 'result = withdrawal_paths([r1, r2]; inflation = 2, frequency = "quarter")'))
case("wp_list1", paste0(SIM_R, "withdrawal_paths(list(r1, r2), frequency = 'year')"), paste0(SIM_P, "result = withdrawal_paths([r1, r2], frequency='year')"), Is,
     jl = paste0(SIM_J, 'result = withdrawal_paths([r1, r2]; frequency = "year")'))
case("wp_list_err", paste0(SIM_R, "withdrawal_paths(list(r1, r2), inflation = 'cpi')"), paste0(SIM_P, "result = withdrawal_paths([r1, r2], inflation='cpi')"), Is,
     jl = paste0(SIM_J, 'result = withdrawal_paths([r1, r2]; inflation = "cpi")'))
case("wp_list_len", paste0(SIM_R, "r3 <- simulation(dsim[1:800, ], st); withdrawal_paths(list(r1, r3))"), paste0(SIM_P, "r3 = simlev.simulation(dsim.iloc[:800], st); result = withdrawal_paths([r1, r3])"), Is,
     jl = paste0(SIM_J, 'r3 = simulation(SL.rows(dsim, 1:800), st); result = withdrawal_paths([r1, r3])'))
case("wp_list_short", paste0(SIM_R, "r3 <- simulation(dsim[1:300, ], st); withdrawal_paths(list(r3))"), paste0(SIM_P, "r3 = simlev.simulation(dsim.iloc[:300], st); result = withdrawal_paths([r3])"), Is,
     jl = paste0(SIM_J, 'r3 = simulation(SL.rows(dsim, 1:300), st); result = withdrawal_paths([r3])'))
wcase("ws_list", paste0("{", SIM_R, "withdrawal_simulation(list(r1, r2), withdrawal_rule('guyton_klinger', rate = 5), inflation = 2)}"),
      paste0("None\n", SIM_P, "ws = withdrawal_simulation([r1, r2], rule=withdrawal_rule(type='guyton_klinger', rate=5), inflation=2)"), Is,
     jl = paste0("nothing\n", SIM_J, 'ws = withdrawal_simulation([r1, r2], withdrawal_rule("guyton_klinger"; rate = 5); inflation = 2)'))
TAX_R <- "rt <- simulation(dsim, create_strategy(ETF = asset_config('etf', 'bnh', spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))\n"
TAX_J <- 'rt = simulation(dsim, create_strategy(ETF = asset_config("etf", "bnh", spread = 0.2, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 2))\n'
TAX_P <- "rt = simlev.simulation(dsim, simlev.create_strategy(ETF=simlev.asset_config(asset_class='etf', trading='bnh', spread=0.2, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=2))\n"
wcase("ws_sv_result", paste0("{", TAX_R, "withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = rt, tax = tax_profile())}"),
      paste0("None\n", TAX_P, "ws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=rt, tax=simlev.tax_profile())"), Is,
     jl = paste0("nothing\n", TAX_J, 'ws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = rt, tax = SL.tax_profile())'))
wcase("ws_sv_result_cb", paste0("{", TAX_R, "withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = rt, tax = tax_profile(), cost_basis = 55, partial_exemption = 15)}"),
      paste0("None\n", TAX_P, "ws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=rt, tax=simlev.tax_profile(), cost_basis=55, partial_exemption=15)"), Is,
     jl = paste0("nothing\n", TAX_J, 'ws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = rt, tax = SL.tax_profile(), cost_basis = 55, partial_exemption = 15)'))
wcase("ws_sv_result_none", paste0("{", SIM_R, "withdrawal_simulation(R[, 1:3], withdrawal_rule('percent', rate = 5), start_value = r2, tax = tax_profile())}"),
      paste0("None\n", SIM_P, "ws = withdrawal_simulation(R[:, :3], rule=withdrawal_rule(type='percent', rate=5), start_value=r2, tax=simlev.tax_profile())"), Is,
     jl = paste0("nothing\n", SIM_J, 'ws = withdrawal_simulation(R[:, 1:3], withdrawal_rule("percent"; rate = 5); start_value = r2, tax = SL.tax_profile())'))
wcase("ws_sv_result_notax", paste0("{", TAX_R, "withdrawal_simulation(rt, withdrawal_rule('percent', rate = 5), start_value = rt, tax = tax_profile(), years = 2)}"),
      paste0("None\n", TAX_P, "ws = withdrawal_simulation(rt, rule=withdrawal_rule(type='percent', rate=5), start_value=rt, tax=simlev.tax_profile(), years=2)"), Is,
     jl = paste0("nothing\n", TAX_J, 'ws = withdrawal_simulation(rt, withdrawal_rule("percent"; rate = 5); start_value = rt, tax = SL.tax_profile(), years = 2)'))

# Bootstrap-Pfade und Studien
set.seed(21); nb <- 1100
db <- data.frame(us = 100 * cumprod(c(1, 1 + rnorm(nb, 3e-4, 0.01))), cpi = 100 * 1.02^((0:nb) / 365), infl = 2, zins = 2 + sin((0:nb) / 40))
Ib <- c(Is, list(db = db))
BR_R <- "cfg <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices', aux_type = c(infl = 'rate', cpi = 'level'))
cfg0 <- bootstrap_config(c(us = 'us'), aux = c(cpi = 'cpi', infl = 'infl', zins = 'zins'), input = 'prices')
b <- bootstrap(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)
b0 <- bootstrap(db, cfg0, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE)\n"
BR_J <- 'cfg = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices", aux_type = (infl = "rate", cpi = "level"))
cfg0 = bootstrap_config((us = "us",), aux = (cpi = "cpi", infl = "infl", zins = "zins"), input = "prices")
b = bootstrap(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
b0 = bootstrap(db, cfg0, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false)
'
BR_P <- "cfg = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices', aux_type={'infl': 'rate', 'cpi': 'level'})
cfg0 = bootstrap_config({'us': 'us'}, aux={'cpi': 'cpi', 'infl': 'infl', 'zins': 'zins'}, input='prices')
b = bootstrap(db, cfg, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)
b0 = bootstrap(db, cfg0, method='stationary', n=3, params={'L': 60}, seed=4, progress=False)\n"
WP <- list(
  plain = c("withdrawal_paths(b, column = 'us')", "withdrawal_paths(b, column='us')",
    'withdrawal_paths(b; column = "us")'),
  num = c("withdrawal_paths(b, column = 'us', inflation = 2, frequency = 'quarter', start = '2001-01-31')", "withdrawal_paths(b, column='us', inflation=2, frequency='quarter', start='2001-01-31')",
    'withdrawal_paths(b; column = "us", inflation = 2, frequency = "quarter", start = "2001-01-31")'),
  rate_attr = c("withdrawal_paths(b, column = 'us', inflation = 'infl')", "withdrawal_paths(b, column='us', inflation='infl')",
    'withdrawal_paths(b; column = "us", inflation = "infl")'),
  level_attr = c("withdrawal_paths(b, column = 'us', inflation = 'cpi', frequency = 'month')", "withdrawal_paths(b, column='us', inflation='cpi', frequency='month')",
    'withdrawal_paths(b; column = "us", inflation = "cpi", frequency = "month")'),
  level_aux = c("withdrawal_paths(b0, column = 'us', inflation = 'zins')", "withdrawal_paths(b0, column='us', inflation='zins')",
    'withdrawal_paths(b0; column = "us", inflation = "zins")'),
  rate_pa = c("withdrawal_paths(b0, column = 'us', inflation = 'zins', inflation_type = 'rate_pa')", "withdrawal_paths(b0, column='us', inflation='zins', inflation_type='rate_pa')",
    'withdrawal_paths(b0; column = "us", inflation = "zins", inflation_type = "rate_pa")'),
  cape = c("withdrawal_paths(b, column = 'us', cape = 'zins', frequency = 'quarter')", "withdrawal_paths(b, column='us', cape='zins', frequency='quarter')",
    'withdrawal_paths(b; column = "us", cape = "zins", frequency = "quarter")'),
  cape1 = c("withdrawal_paths(b, column = 'us', cape = 'zins', dates = seq.Date(as.Date('2003-02-28'), by = 'day', length.out = 1101))", "withdrawal_paths(b, column='us', cape='zins', dates=np.datetime64('2003-02-28') + np.arange(1101))",
    'withdrawal_paths(b; column = "us", cape = "zins", dates = Date(2003, 2, 28) .+ Day.(0:1100))'),
  td = c("x <- seq.Date(as.Date('2001-01-01'), by = 'day', length.out = 2000); x <- x[!format(x, '%u') %in% c('6', '7')][1:1101]; withdrawal_paths(b, column = 'us', inflation = 'infl', dates = x)",
         "x = np.datetime64('2001-01-01') + np.arange(2000); x = x[(x.astype(int) + 3) % 7 < 5][:1101]; result = withdrawal_paths(b, column='us', inflation='infl', dates=x)",
    'x = Date(2001, 1, 1) .+ Day.(0:1999); x = x[Dates.dayofweek.(x) .< 6][1:1101]; result = withdrawal_paths(b; column = "us", inflation = "infl", dates = x)'),
  e_col = c("withdrawal_paths(b)", "withdrawal_paths(b)",
    'withdrawal_paths(b)'),
  e_colname = c("withdrawal_paths(b, column = 'x')", "withdrawal_paths(b, column='x')",
    'withdrawal_paths(b; column = "x")'),
  e_dates = c("withdrawal_paths(b, column = 'us', dates = as.Date('2001-01-01') + 0:5)", "withdrawal_paths(b, column='us', dates=np.datetime64('2001-01-01') + np.arange(6))",
    'withdrawal_paths(b; column = "us", dates = Date(2001, 1, 1) .+ Day.(0:5))'),
  e_unsorted = c("withdrawal_paths(b, column = 'us', dates = rev(as.Date('2001-01-01') + 0:1100))", "withdrawal_paths(b, column='us', dates=(np.datetime64('2001-01-01') + np.arange(1101))[::-1])",
    'withdrawal_paths(b; column = "us", dates = reverse(Date(2001, 1, 1) .+ Day.(0:1100)))'),
  e_short = c("b3 <- bootstrap(db, cfg, 'raw', n = 1, seed = 1, progress = FALSE, path_length = 200); withdrawal_paths(b3, column = 'us')", "b3 = bootstrap(db, cfg, method='raw', n=1, seed=1, progress=False, path_length=200); result = withdrawal_paths(b3, column='us')",
    'b3 = bootstrap(db, cfg, "raw"; n = 1, seed = 1, progress = false, path_length = 200); result = withdrawal_paths(b3; column = "us")'),
  e_dup = c("withdrawal_paths(b, column = 'us', dates = as.Date('2001-01-01') + (0:1100) %/% 3)", "withdrawal_paths(b, column='us', dates=np.datetime64('2001-01-01') + np.arange(1101) // 3)",
    'withdrawal_paths(b; column = "us", dates = Date(2001, 1, 1) .+ Day.((0:1100) .÷ 3))'),
  e_infl_col = c("withdrawal_paths(b, column = 'us', inflation = 'cp')", "withdrawal_paths(b, column='us', inflation='cp')",
    'withdrawal_paths(b; column = "us", inflation = "cp")'),
  e_mismatch = c("withdrawal_paths(b, column = 'us', inflation = 'infl', inflation_type = 'level')", "withdrawal_paths(b, column='us', inflation='infl', inflation_type='level')",
    'withdrawal_paths(b; column = "us", inflation = "infl", inflation_type = "level")'),
  e_mismatch2 = c("withdrawal_paths(b, column = 'us', inflation = 'cpi', inflation_type = 'rate_pa')", "withdrawal_paths(b, column='us', inflation='cpi', inflation_type='rate_pa')",
    'withdrawal_paths(b; column = "us", inflation = "cpi", inflation_type = "rate_pa")'),
  e_infl_vec = c("withdrawal_paths(b, column = 'us', inflation = c(1, 2))", "withdrawal_paths(b, column='us', inflation=[1, 2])",
    'withdrawal_paths(b; column = "us", inflation = [1, 2])'),
  e_noattr = c("b0$paths <- lapply(b0$paths, function(p) { attr(p, 'aux_level') <- NULL; p }); withdrawal_paths(b0, column = 'us', inflation = 'zins')",
               "[p.attrs.pop('aux_level') for p in b0['paths']]; result = withdrawal_paths(b0, column='us', inflation='zins')",
    'for p in b0["paths"]; delete!(p.attrs, "aux_level"); end; result = withdrawal_paths(b0; column = "us", inflation = "zins")'),
  wild_noattr = c("b0$paths <- lapply(b0$paths, function(p) { attr(p, 'aux_level') <- NULL; p }); b0$method <- 'wild'; withdrawal_paths(b0, column = 'us', inflation = 'zins')",
                  "[p.attrs.pop('aux_level') for p in b0['paths']]; b0['method'] = 'wild'; result = withdrawal_paths(b0, column='us', inflation='zins')",
    'for p in b0["paths"]; delete!(p.attrs, "aux_level"); end; b0["method"] = "wild"; result = withdrawal_paths(b0; column = "us", inflation = "zins")'),
  e_class = c("withdrawal_paths(list(1, 2))", "withdrawal_paths([1, 2])",
    'withdrawal_paths([1, 2])'))
for (k in names(WP)) case(paste0("wp_", k), paste0(BR_R, WP[[k]][1]), paste0(BR_P, if (grepl("result = ", WP[[k]][2], fixed = TRUE)) "" else "result = ", WP[[k]][2]), Ib,
                          jl = paste0(BR_J, if (grepl("result = ", WP[[k]][3], fixed = TRUE)) "" else "result = ", WP[[k]][3]))
case("wp_rate_neg", "d2 <- db; d2$infl <- -150; b2 <- bootstrap(d2, bootstrap_config(c(us = 'us'), aux = c(infl = 'infl'), input = 'prices', aux_type = c(infl = 'rate')), 'raw', n = 1, seed = 1, progress = FALSE); withdrawal_paths(b2, column = 'us', inflation = 'infl')",
     "d2 = db.copy(); d2['infl'] = -150.0; b2 = bootstrap(d2, bootstrap_config({'us': 'us'}, aux={'infl': 'infl'}, input='prices', aux_type={'infl': 'rate'}), method='raw', n=1, seed=1, progress=False); result = withdrawal_paths(b2, column='us', inflation='infl')", Ib,
     jl = 'd2 = copy(db); d2["infl"] = fill(-150.0, SL.nrow(d2)); b2 = bootstrap(d2, bootstrap_config((us = "us",), aux = (infl = "infl",), input = "prices", aux_type = (infl = "rate",)), "raw"; n = 1, seed = 1, progress = false); result = withdrawal_paths(b2; column = "us", inflation = "infl")')
case("wp_level_neg", "d2 <- db; d2$zins <- d2$zins - 2.5; b2 <- bootstrap(d2, bootstrap_config(c(us = 'us'), aux = c(zins = 'zins'), input = 'prices'), 'raw', n = 1, seed = 1, progress = FALSE); withdrawal_paths(b2, column = 'us', inflation = 'zins')",
     "d2 = db.copy(); d2['zins'] = d2['zins'] - 2.5; b2 = bootstrap(d2, bootstrap_config({'us': 'us'}, aux={'zins': 'zins'}, input='prices'), method='raw', n=1, seed=1, progress=False); result = withdrawal_paths(b2, column='us', inflation='zins')", Ib,
     jl = 'd2 = copy(db); d2["zins"] = d2.zins .- 2.5; b2 = bootstrap(d2, bootstrap_config((us = "us",), aux = (zins = "zins",), input = "prices"), "raw"; n = 1, seed = 1, progress = false); result = withdrawal_paths(b2; column = "us", inflation = "zins")')
case("wp_ess_weights", "b2 <- bootstrap(db, bootstrap_config(c(us = 'us')), 'stationary', n = 5, ess = TRUE, ess_grid = list(L = c(10, 80)), seed = 3, progress = FALSE); withdrawal_paths(b2, column = 'us', inflation = 1)",
     "b2 = bootstrap(db, bootstrap_config({'us': 'us'}), method='stationary', n=5, ess=True, ess_grid={'L': [10, 80]}, seed=3, progress=False); result = withdrawal_paths(b2, column='us', inflation=1)", Ib,
     jl = 'b2 = bootstrap(db, bootstrap_config((us = "us",)), "stationary"; n = 5, ess = true, ess_grid = (L = [10, 80],), seed = 3, progress = false); result = withdrawal_paths(b2; column = "us", inflation = 1)')
case("coh_bd_attr", paste0(BR_R, "x <- bootstrap_data(b, 1, dates = seq.Date(as.Date('2001-01-01'), by = 'day', length.out = 1101)); withdrawal_cohorts(x, price = 'us', inflation = 'infl', years = 1, step = 'year')"),
     paste0(BR_P, "x = bootstrap_data(b, i=1, dates=np.datetime64('2001-01-01') + np.arange(1101)); result = withdrawal_cohorts(x, price='us', inflation='infl', years=1, step='year')"), Ib,
     jl = paste0(BR_J, 'x = bootstrap_data(b, 1; dates = Date(2001, 1, 1) .+ Day.(0:1100)); result = withdrawal_cohorts(x; price = "us", inflation = "infl", years = 1, step = "year")'))
case("coh_bd_attr_err", paste0(BR_R, "x <- bootstrap_data(b, 1); withdrawal_cohorts(x, price = 'us', inflation = 'infl', years = 1, inflation_type = 'level')"),
     paste0(BR_P, "x = bootstrap_data(b, i=1); result = withdrawal_cohorts(x, price='us', inflation='infl', years=1, inflation_type='level')"), Ib,
     jl = paste0(BR_J, 'x = bootstrap_data(b, 1); result = withdrawal_cohorts(x; price = "us", inflation = "infl", years = 1, inflation_type = "level")'))
case("coh_bd_attr_ok", paste0(BR_R, "x <- bootstrap_data(b, 2); withdrawal_cohorts(x, price = 'us', inflation = 'infl', years = 1, inflation_type = 'rate_pa', step = 'year')"),
     paste0(BR_P, "x = bootstrap_data(b, i=2); result = withdrawal_cohorts(x, price='us', inflation='infl', years=1, inflation_type='rate_pa', step='year')"), Ib,
     jl = paste0(BR_J, 'x = bootstrap_data(b, 2); result = withdrawal_cohorts(x; price = "us", inflation = "infl", years = 1, inflation_type = "rate_pa", step = "year")'))
ST_R <- paste0(BR_R, "st <- bootstrap_study(db, cfg, 'stationary', n = 3, params = list(L = 60), seed = 4, progress = FALSE, keep_returns = 'year', keep_aux = c('infl', 'zins', 'cpi'), strategies = list(bnh = create_strategy(us = asset_config('etf', 'bnh')), half = create_strategy(us = asset_config('etf', 'bnh', share = 0.5))))\n")
ST_J <- paste0(BR_J, 'st = bootstrap_study(db, cfg, "stationary"; n = 3, params = (L = 60,), seed = 4, progress = false, keep_returns = "year", keep_aux = ["infl", "zins", "cpi"], strategies = (bnh = create_strategy(us = asset_config("etf", "bnh")), half = create_strategy(us = asset_config("etf", "bnh", share = 0.5))))\n')
ST_P <- paste0(BR_P, "st = bootstrap_study(db, cfg, 'stationary', n=3, params={'L': 60}, seed=4, progress=False, keep_returns='year', keep_aux=['infl', 'zins', 'cpi'], strategies={'bnh': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh')), 'half': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5))})\n")
SW <- list(
  default = c("withdrawal_paths(st)", "withdrawal_paths(st)",
    'withdrawal_paths(st)'),
  strat = c("withdrawal_paths(st, strategy = 'half', inflation = 2)", "withdrawal_paths(st, strategy='half', inflation=2)",
    'withdrawal_paths(st; strategy = "half", inflation = 2)'),
  aux_rate = c("withdrawal_paths(st, inflation = 'infl')", "withdrawal_paths(st, inflation='infl')",
    'withdrawal_paths(st; inflation = "infl")'),
  aux_level = c("withdrawal_paths(st, inflation = 'zins', inflation_type = 'level')", "withdrawal_paths(st, inflation='zins', inflation_type='level')",
    'withdrawal_paths(st; inflation = "zins", inflation_type = "level")'),
  aux_cpi = c("withdrawal_paths(st, inflation = 'cpi')", "withdrawal_paths(st, inflation='cpi')",
    'withdrawal_paths(st; inflation = "cpi")'),
  e_rate_pa = c("withdrawal_paths(st, inflation = 'zins', inflation_type = 'rate_pa')", "withdrawal_paths(st, inflation='zins', inflation_type='rate_pa')",
    'withdrawal_paths(st; inflation = "zins", inflation_type = "rate_pa")'),
  e_mismatch = c("withdrawal_paths(st, inflation = 'infl', inflation_type = 'level')", "withdrawal_paths(st, inflation='infl', inflation_type='level')",
    'withdrawal_paths(st; inflation = "infl", inflation_type = "level")'),
  e_strat = c("withdrawal_paths(st, strategy = 'x')", "withdrawal_paths(st, strategy='x')",
    'withdrawal_paths(st; strategy = "x")'),
  e_aux = c("withdrawal_paths(st, inflation = 'foo')", "withdrawal_paths(st, inflation='foo')",
    'withdrawal_paths(st; inflation = "foo")'),
  ws = c("{ws <- withdrawal_simulation(st, withdrawal_rule('constant'), strategy = 'half', inflation = 'infl'); ws$elapsed <- 0; ws}", "withdrawal_simulation(st, rule=withdrawal_rule(type='constant'), strategy='half', inflation='infl'); result['elapsed'] = 0",
    '(ws = withdrawal_simulation(st, withdrawal_rule("constant"); strategy = "half", inflation = "infl"); ws["elapsed"] = 0; ws)'))
for (k in names(SW)) case(paste0("wps_", k), paste0(ST_R, SW[[k]][1]), paste0(ST_P, "result = ", SW[[k]][2]), Ib, jl = paste0(ST_J, "result = ", SW[[k]][3]))
case("wps_noreturns", "st <- bootstrap_study(db, bootstrap_config(c(us = 'us'), input = 'prices'), 'raw', n = 2, path_length = 400, seed = 1, progress = FALSE, strategies = list(a = create_strategy(us = asset_config('etf', 'bnh')))); withdrawal_paths(st)",
     "st = bootstrap_study(db, bootstrap_config({'us': 'us'}, input='prices'), 'raw', n=2, path_length=400, seed=1, progress=False, strategies={'a': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh'))}); result = withdrawal_paths(st)", Ib,
     jl = 'st = bootstrap_study(db, bootstrap_config((us = "us",), input = "prices"), "raw"; n = 2, path_length = 400, seed = 1, progress = false, strategies = (a = create_strategy(us = asset_config("etf", "bnh")),)); result = withdrawal_paths(st)')
case("wps_neg_level", "d2 <- db; d2$zins <- d2$zins - 2.5; st <- suppressWarnings(bootstrap_study(d2, bootstrap_config(c(us = 'us'), aux = c(zins = 'zins'), input = 'prices'), 'stationary', n = 2, params = list(L = 50), seed = 1, progress = FALSE, keep_returns = 'year', keep_aux = 'zins', strategies = list(a = create_strategy(us = asset_config('etf', 'bnh'))))); withdrawal_paths(st, inflation = 'zins')",
     "d2 = db.copy(); d2['zins'] = d2['zins'] - 2.5\nimport warnings as _w\nwith _w.catch_warnings():\n    _w.simplefilter('ignore')\n    st = bootstrap_study(d2, bootstrap_config({'us': 'us'}, aux={'zins': 'zins'}, input='prices'), 'stationary', n=2, params={'L': 50}, seed=1, progress=False, keep_returns='year', keep_aux='zins', strategies={'a': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh'))})\nresult = withdrawal_paths(st, inflation='zins')", Ib,
     jl = 'd2 = copy(db); d2["zins"] = d2.zins .- 2.5; st = B._quiet(() -> bootstrap_study(d2, bootstrap_config((us = "us",), aux = (zins = "zins",), input = "prices"), "stationary"; n = 2, params = (L = 50,), seed = 1, progress = false, keep_returns = "year", keep_aux = "zins", strategies = (a = create_strategy(us = asset_config("etf", "bnh")),))); result = withdrawal_paths(st; inflation = "zins")')
case("study_keepaux_warn", "d2 <- db; d2$zins <- d2$zins - 2.5; st <- bootstrap_study(d2, bootstrap_config(c(us = 'us'), aux = c(zins = 'zins', z2 = 'zins'), input = 'prices', aux_type = c(z2 = 'rate')), 'stationary', n = 2, params = list(L = 50), seed = 1, progress = FALSE, keep_returns = 'year', keep_aux = c('zins', 'z2'), strategies = list(a = create_strategy(us = asset_config('etf', 'bnh')))); st$aux_returns",
     "d2 = db.copy(); d2['zins'] = d2['zins'] - 2.5; st = bootstrap_study(d2, bootstrap_config({'us': 'us'}, aux={'zins': 'zins', 'z2': 'zins'}, input='prices', aux_type={'z2': 'rate'}), 'stationary', n=2, params={'L': 50}, seed=1, progress=False, keep_returns='year', keep_aux=['zins', 'z2'], strategies={'a': simlev.create_strategy(us=simlev.asset_config(asset_class='etf', trading='bnh'))}); result = st['aux_returns']", Ib,
     jl = 'd2 = copy(db); d2["zins"] = d2.zins .- 2.5; st = bootstrap_study(d2, bootstrap_config((us = "us",), aux = (zins = "zins", z2 = "zins"), input = "prices", aux_type = (z2 = "rate",)), "stationary"; n = 2, params = (L = 50,), seed = 1, progress = false, keep_returns = "year", keep_aux = ["zins", "z2"], strategies = (a = create_strategy(us = asset_config("etf", "bnh")),)); result = st["aux_returns"]')

# ── FIFO-Lots und Übernahme aus einer Ansparphase ──────────────────────────
dfi <- data.frame(date = seq.Date(as.Date("2018-01-01"), as.Date("2019-12-31"), by = "day"))
tt <- as.numeric(dfi$date - dfi$date[1]) / 365.25
dfi$A <- 100 * (1 - 0.3 * sin(3 * tt)); dfi$N <- 100 * 1.03^tt; dfi$C <- dfi$N
dfi$ev <- dfi$date %in% as.Date(c("2018-01-01", "2018-07-01", "2019-03-01")); dfi$wA <- c(1, 0.2, 0.6)[pmax(1, cumsum(dfi$ev))]; dfi$wN <- 1 - dfi$wA
If <- c(I, list(dfi = dfi))
FI_R <- function(a2 = "asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15)", extra = "", tax = "")
  sprintf("st <- create_strategy(A = asset_config('etf', 'bnh', share = 0.5, spread = 0.2, partial_exemption = 15), N = %s)\nr <- suppressWarnings(simulation(dfi, st, start_value = 1e5, rebalance = rebalance_plan(event_col = 'ev', event_mode = 'replace', skip = TRUE, event_weight = c(A = 'wA', N = 'wN')), tax = tax_profile(base_rate = 1%s)%s))\n", a2, tax, extra)
FI_J <- function(a2 = 'asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15)', extra = "", tax = "")
  sprintf('st = create_strategy(A = asset_config("etf", "bnh", share = 0.5, spread = 0.2, partial_exemption = 15), N = %s)\nr = B._quiet(() -> simulation(dfi, st; start_value = 1e5, rebalance = rebalance_plan(; event_col = "ev", event_mode = "replace", skip = true, event_weight = (A = "wA", N = "wN")), tax = tax_profile(; base_rate = 1%s)%s))\n', a2, tax, extra)
FI_P <- function(a2 = "simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15)", extra = "", tax = "")
  sprintf("import warnings as _w\nst = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.5, spread=0.2, partial_exemption=15), N=%s)\nwith _w.catch_warnings():\n    _w.simplefilter('ignore')\n    r = simlev.simulation(dfi, st, start_value=1e5, rebalance=simlev.rebalance_plan(event_col='ev', event_mode='replace', skip=True, event_weight={'A': 'wA', 'N': 'wN'}), tax=simlev.tax_profile(base_rate=1%s)%s)\n", a2, tax, extra)
wcase("fifo_adopt", paste0("{", FI_R(), "withdrawal_simulation(matrix(1.02, 3, 2), start_value = r, tax = tax_profile())}"),
      paste0("None\n", FI_P(), "ws = withdrawal_simulation(np.full((3, 2), 1.02), start_value=r, tax=simlev.tax_profile())"), If,
     jl = paste0("nothing\n", FI_J(), 'ws = withdrawal_simulation(fill(1.02, 3, 2); start_value = r, tax = SL.tax_profile())'))
wcase("fifo_explicit", paste0("{", FI_R(), "withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile(), partial_exemption = 30, loss_carryforward = 0, sale_cost = 0)}"),
      paste0("None\n", FI_P(), "ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile(), partial_exemption=30, loss_carryforward=0, sale_cost=0)"), If,
     jl = paste0("nothing\n", FI_J(), 'ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile(), partial_exemption = 30, loss_carryforward = 0, sale_cost = 0)'))
wcase("fifo_old_ny", paste0("{", FI_R(), "r$tax_report$next_year <- NULL; r$tax_report$loss_carryforward_capital <- 1234; withdrawal_simulation(matrix(1.03, 4, 1), withdrawal_rule('percent'), start_value = r, tax = tax_profile(), timing = 'end')}"),
      paste0("None\n", FI_P(), "del r['tax_report']['next_year']; r['tax_report']['loss_carryforward_capital'] = 1234.0; ws = withdrawal_simulation(np.full((4, 1), 1.03), rule=withdrawal_rule(type='percent'), start_value=r, tax=simlev.tax_profile(), timing='end')"), If,
     jl = paste0("nothing\n", FI_J(), 'delete!(r["tax_report"], "next_year"); r["tax_report"]["loss_carryforward_capital"] = 1234.0; ws = withdrawal_simulation(fill(1.03, 4, 1), withdrawal_rule("percent"); start_value = r, tax = SL.tax_profile(), timing = "end")'))
wcase("fifo_spreads", paste0("{", FI_R(), "r$open_lots$N$spread <- 0.5; withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}"),
      paste0("None\n", FI_P(), "r['open_lots']['N']['spread'] = 0.5; ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile())"), If,
     jl = paste0("nothing\n", FI_J(), 'r["open_lots"]["N"]["spread"] = 0.5; ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile())'))
wcase("fifo_nospread", paste0("{", FI_R(), "for (a in names(r$open_lots)) r$open_lots[[a]]$spread <- NULL; withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}"),
      paste0("None\n", FI_P(), "[r['open_lots'][a].pop('spread') for a in r['open_lots']]; ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile())"), If,
     jl = paste0("nothing\n", FI_J(), 'for a in keys(r["open_lots"]); delete!(r["open_lots"][a], "spread"); end; ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile())'))
wcase("fifo_fee", paste0("{", FI_R(extra = ", costs = sim_costs(order_fee = 1)"), "withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}"),
      paste0("None\n", FI_P(extra = ", costs=simlev.sim_costs(order_fee=1)"), "ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile())"), If,
     jl = paste0("nothing\n", FI_J(extra = ", costs = sim_costs(; order_fee = 1)"), 'ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile())'))
wcase("fifo_fee_zero", paste0("{", FI_R(extra = ", costs = sim_costs(order_fee = 1)"), "r$open_lots$A$order_fee <- list(fixed = 0, percent = 0, min = 0, max = Inf); r$open_lots$N$order_fee <- NULL; withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}"),
      paste0("None\n", FI_P(extra = ", costs=simlev.sim_costs(order_fee=1)"), "r['open_lots']['A']['order_fee'] = {'fixed': 0, 'percent': 0, 'min': 0, 'max': np.inf}; r['open_lots']['N']['order_fee'] = None; ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile())"), If,
     jl = paste0("nothing\n", FI_J(extra = ", costs = sim_costs(; order_fee = 1)"), 'r["open_lots"]["A"]["order_fee"] = (fixed = 0, percent = 0, min = 0, max = Inf); delete!(r["open_lots"]["N"], "order_fee"); ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile())'))
wcase("fifo_mixed", paste0("{", FI_R("asset_config('etn', 'bnh', share = 0.5, spread = 0.2)"), "withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}"),
      paste0("None\n", FI_P("simlev.asset_config(asset_class='etn', trading='bnh', share=0.5, spread=0.2)"), "ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile())"), If,
     jl = paste0("nothing\n", FI_J('asset_config("etn", "bnh", share = 0.5, spread = 0.2)'), 'ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile())'))
wcase("fifo_private", paste0("{", FI_R("asset_config('etc', 'bnh', share = 0.5, spread = 0.2, deliverable = TRUE)", tax = ", income = income_rate(42)"), "withdrawal_simulation(matrix(1.02, 3, 1), start_value = r, tax = tax_profile())}"),
      paste0("None\n", FI_P("simlev.asset_config(asset_class='etc', trading='bnh', share=0.5, spread=0.2, deliverable=True)", tax = ", income=simlev.income_rate(42)"), "ws = withdrawal_simulation(np.full((3, 1), 1.02), start_value=r, tax=simlev.tax_profile())"), If,
     jl = paste0("nothing\n", FI_J('asset_config("etc", "bnh", share = 0.5, spread = 0.2, deliverable = true)', tax = ", income = income_rate(42)"), 'ws = withdrawal_simulation(fill(1.02, 3, 1); start_value = r, tax = SL.tax_profile())'))
wcase("fifo_etn", "{r <- simulation(dfi, create_strategy(N = asset_config('etn', 'bnh', spread = 0)), start_value = 1e5, tax = tax_profile(base_rate = 3)); withdrawal_simulation(matrix(1.10, 3, 1), withdrawal_rule('constant', rate = 1), start_value = r, tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 3)}",
      "None\nr = simlev.simulation(dfi, simlev.create_strategy(N=simlev.asset_config(asset_class='etn', trading='bnh', spread=0)), start_value=1e5, tax=simlev.tax_profile(base_rate=3)); ws = withdrawal_simulation(np.full((3, 1), 1.10), rule=withdrawal_rule(type='constant', rate=1), start_value=r, tax=simlev.tax_profile(sparer_pauschbetrag=0), base_rate=3)", If,
     jl = paste0("nothing\n", "", 'r = simulation(dfi, create_strategy(N = asset_config("etn", "bnh", spread = 0)), start_value = 1e5, tax = tax_profile(base_rate = 3)); ws = withdrawal_simulation(fill(1.10, 3, 1), withdrawal_rule("constant"; rate = 1); start_value = r, tax = SL.tax_profile(; sparer_pauschbetrag = 0), base_rate = 3)'))
wcase("fifo_etn_vp", "{r <- simulation(dfi, create_strategy(N = asset_config('etn', 'bnh', spread = 0)), start_value = 1e5, tax = tax_profile(base_rate = 3)); withdrawal_simulation(matrix(1.10, 3, 1), withdrawal_rule('constant', rate = 1), start_value = r, tax = tax_profile(sparer_pauschbetrag = 0), base_rate = 3, vorabpauschale = TRUE)}",
      "None\nr = simlev.simulation(dfi, simlev.create_strategy(N=simlev.asset_config(asset_class='etn', trading='bnh', spread=0)), start_value=1e5, tax=simlev.tax_profile(base_rate=3)); ws = withdrawal_simulation(np.full((3, 1), 1.10), rule=withdrawal_rule(type='constant', rate=1), start_value=r, tax=simlev.tax_profile(sparer_pauschbetrag=0), base_rate=3, vorabpauschale=True)", If,
     jl = paste0("nothing\n", "", 'r = simulation(dfi, create_strategy(N = asset_config("etn", "bnh", spread = 0)), start_value = 1e5, tax = tax_profile(base_rate = 3)); ws = withdrawal_simulation(fill(1.10, 3, 1), withdrawal_rule("constant"; rate = 1); start_value = r, tax = SL.tax_profile(; sparer_pauschbetrag = 0), base_rate = 3, vorabpauschale = true)'))
wcase("fifo_ny_spb", "{r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh', spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2)); withdrawal_simulation(matrix(1.1, 3, 1), withdrawal_rule('constant', rate = 4), start_value = r, tax = tax_profile(sparer_pauschbetrag = 2000), base_rate = 3.2)}",
      "None\nr = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', spread=0, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=3.2)); ws = withdrawal_simulation(np.full((3, 1), 1.1), rule=withdrawal_rule(type='constant', rate=4), start_value=r, tax=simlev.tax_profile(sparer_pauschbetrag=2000), base_rate=3.2)", If,
     jl = paste0("nothing\n", "", 'r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh", spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2)); ws = withdrawal_simulation(fill(1.1, 3, 1), withdrawal_rule("constant"; rate = 4); start_value = r, tax = SL.tax_profile(; sparer_pauschbetrag = 2000), base_rate = 3.2)'))
wcase("fifo_liquidate", "{r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh', spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2), liquidate = TRUE); withdrawal_simulation(matrix(1.05, 3, 1), start_value = r, tax = tax_profile())}",
      "None\nr = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', spread=0, partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=3.2), liquidate=True); ws = withdrawal_simulation(np.full((3, 1), 1.05), start_value=r, tax=simlev.tax_profile())", If,
     jl = paste0("nothing\n", "", 'r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh", spread = 0, partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3.2), liquidate = true); ws = withdrawal_simulation(fill(1.05, 3, 1); start_value = r, tax = SL.tax_profile())'))
case("sv_negative", "r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh')), start_value = 1e4); r$worth[length(r$worth)] <- -800; r$tax_report$open_tax_debt <- 800; withdrawal_simulation(matrix(1.03, 5, 1), start_value = r, tax = tax_profile())",
     "r = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh')), start_value=1e4); w = np.array(r['worth'], dtype=float); w[-1] = -800; r['worth'] = w; r['tax_report']['open_tax_debt'] = 800.0; result = withdrawal_simulation(np.full((5, 1), 1.03), start_value=r, tax=simlev.tax_profile())", If,
     jl = 'r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh")); start_value = 1e4); r["worth"][end] = -800; r["tax_report"]["open_tax_debt"] = 800.0; result = withdrawal_simulation(fill(1.03, 5, 1); start_value = r, tax = SL.tax_profile())')
wcase("ws_src_taxed", "{r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh', partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3)); withdrawal_simulation(list(r, r), withdrawal_rule('percent'), tax = tax_profile(), inflation = 1)}",
      "None\nr = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=3)); ws = withdrawal_simulation([r, r], rule=withdrawal_rule(type='percent'), tax=simlev.tax_profile(), inflation=1)", If,
     jl = paste0("nothing\n", "", 'r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh", partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3)); ws = withdrawal_simulation([r, r], withdrawal_rule("percent"); tax = SL.tax_profile(), inflation = 1)'))
wcase("ws_src_taxed_coh", "{r <- simulation(dfi, create_strategy(C = asset_config('etf', 'bnh', partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3)); withdrawal_simulation(r, withdrawal_rule('percent'), tax = tax_profile(), years = 1, frequency = 'quarter')}",
      "None\nr = simlev.simulation(dfi, simlev.create_strategy(C=simlev.asset_config(asset_class='etf', trading='bnh', partial_exemption=30)), start_value=1e5, tax=simlev.tax_profile(base_rate=3)); ws = withdrawal_simulation(r, rule=withdrawal_rule(type='percent'), tax=simlev.tax_profile(), years=1, frequency='quarter')", If,
     jl = paste0("nothing\n", "", 'r = simulation(dfi, create_strategy(C = asset_config("etf", "bnh", partial_exemption = 30)), start_value = 1e5, tax = tax_profile(base_rate = 3)); ws = withdrawal_simulation(r, withdrawal_rule("percent"); tax = SL.tax_profile(), years = 1, frequency = "quarter")'))
case("mr_adopt", paste0(FI_R(), "r <- withdrawal_max_rate(matrix(1.03, 10, 5), success = 0.9, start_value = r, tax = tax_profile(), tol = 0.1); list(as.numeric(r), attr(r, 'success'))"),
     paste0(FI_P(), "r = withdrawal_max_rate(np.full((10, 5), 1.03), success=0.9, start_value=r, tax=simlev.tax_profile(), tol=0.1); result = [float(r), r.success]"), If,
     jl = paste0(FI_J(), 'r = withdrawal_max_rate(fill(1.03, 10, 5); success = 0.9, start_value = r, tax = SL.tax_profile(), tol = 0.1); result = [r[1], SL.attrs(r)["success"]]'))

ref_done()
