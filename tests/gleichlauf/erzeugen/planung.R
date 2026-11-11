# tests/gleichlauf/erzeugen/planung.R – Bereich planung als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Planung: verschobene Renditen, gepoolter Bootstrap, Portfoliorenditen, Zielplanung, Szenarien (Entropy Pooling,
# Copula, Krisen) und taktische Allokation (Regeln, Rotation, Zielvolatilität, Gleitpfad), Eingabeprüfungen.
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/planung.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/planung.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/planung.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("planung")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul planning
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev import planning as PL\n"
JH <- "PL = SL.Planning\n"   # Kopf des Julia-Codes (jl)
SH <- function(call) sprintf("x <- %s; list(data = x, shift = attr(x, 'shift'))", call)
PSH <- function(call) paste0(P, sprintf("x = %s\nresult = {'data': x, 'shift': x.attrs['shift']}", call))
# ── series_shift_return ─────────────────────────────────────────────────────
set.seed(1)
d <- data.frame(date = seq.Date(as.Date("2000-01-01"), by = "day", length.out = 1500))
d$us <- exp(rnorm(1500, 3e-4, 0.01)); d$eu <- exp(rnorm(1500, 1e-4, 0.012)); d$x <- 1
pr <- data.frame(date = d$date, us = 100 * cumprod(d$us), eu = 100 * cumprod(d$eu))
set.seed(2); o <- sample(nrow(pr)); prs <- pr[o, ]
dn <- d; dn$us[c(3, 700)] <- NA
I <- list(d = d, pr = pr, prs = prs, dn = dn)
EIN[["planning/ser_named"]] <- I
EIN[["planning/ser_prices_unsorted"]] <- I
EIN[["planning/ser_nodate"]] <- I
EIN[["planning/ser_err_df"]] <- I
EIN[["planning/ser_err_col"]] <- I
EIN[["planning/ser_err_target"]] <- I
EIN[["planning/ser_err_named"]] <- list()
EIN[["planning/ser_err_dup"]] <- I
# ── .period_gross ───────────────────────────────────────────────────────────
pg <- pr[seq(1, 1500, 3), ]; pg$us[c(1, 2, 40)] <- NA
# ── bootstrap_pooled ────────────────────────────────────────────────────────
set.seed(1)
land <- function(mu, n = 70) {
  d <- data.frame(date = seq.Date(as.Date("1950-12-31"), by = "year", length.out = n))
  d$aktien <- 100 * cumprod(exp(rnorm(n, mu, 0.18)))
  d$anleihen <- 100 * cumprod(exp(rnorm(n, 0.02, 0.06)))
  d$cpi <- 100 * cumprod(exp(rnorm(n, 0.025, 0.02)))
  d
}
ds <- list(de = land(0.05), us = land(0.07), jp = land(0.03, 40))
mland <- function(mu, n = 240) {
  d <- data.frame(date = seq.Date(as.Date("1990-01-31"), by = "month", length.out = n))
  d$aktien <- 100 * cumprod(exp(rnorm(n, mu / 12, 0.05))); d$anleihen <- 100 * cumprod(exp(rnorm(n, 0.002, 0.01)))
  d$cpi <- 100 * cumprod(exp(rnorm(n, 0.002, 0.003))); d
}
dm <- list(a = mland(0.06), b = mland(0.02, 180))
dm$b$aktien[c(5, 6)] <- NA
I <- list(ds = ds, dm = dm)
EIN[["planning/pb_default"]] <- I
EIN[["planning/pb_unnamed_w"]] <- I
EIN[["planning/pb_target"]] <- I
EIN[["planning/pb_target_named"]] <- I
EIN[["planning/pb_err_names"]] <- I
EIN[["planning/pb_err_w_neg"]] <- I
EIN[["planning/pb_err_w_names"]] <- I
EIN[["planning/pb_err_few"]] <- I
EIN[["planning/pb_err_freq"]] <- I
# ── portfolio_returns ───────────────────────────────────────────────────────
set.seed(1); n <- 650   # bis 1.4.1 n <- 1300 (kürzer, Abdeckung gleich)
pd0 <- data.frame(date = seq.Date(as.Date("2010-01-01"), by = "3 days", length.out = n))
pd0$aktien <- 100 * cumprod(1 + rnorm(n, 1e-3, 0.02)); pd0$anleihen <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.004))
pd0$gold <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.01)); pd0$gold[1:200] <- NA; pd0$anleihen[c(500, 501)] <- NA
cand <- lapply(c(a20 = 0.2, a60 = 0.6, a100 = 1), function(a) c(aktien = a, anleihen = 1 - a))
I <- list(pd0 = pd0, cand = cand)
PC <- "cand = {k: pd.Series(v) for k, v in cand.items()}\n"
EIN[["planning/pr_quarter"]] <- I
EIN[["planning/pr_month_gold"]] <- I
# ── planning_goal ───────────────────────────────────────────────────────────
set.seed(1)
R <- sapply(c(a20 = 0.2, a60 = 0.6, a100 = 1), function(a) exp(rnorm(120, 0.01 + 0.04 * a, 0.02 + 0.16 * a)))
I <- list(R = R)
EIN[["planning/go_ex"]] <- I
EIN[["planning/go_noname"]] <- I
EIN[["planning/go_df"]] <- I
set.seed(3)
S5 <- cbind(safe = exp(rnorm(5, 0.02, 0.01)), mid = exp(rnorm(5, 0.04, 0.1)), risky = exp(rnorm(5, 0.06, 0.25)))
EIN[["planning/go_warn"]] <- list(S5 = S5)
EIN[["planning/go_err_R"]] <- I
EIN[["planning/go_err_start"]] <- I
EIN[["planning/go_err_goal"]] <- I
EIN[["planning/go_err_h0"]] <- I
EIN[["planning/go_err_grid"]] <- I
EIN[["planning/go_err_sim"]] <- I
EIN[["planning/go_err_cf0"]] <- I

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import planning as PL)",
            jl = r"(PL = SL.Planning)")

ref_init("planning", gruppe = "gleichlauf")
SZ("verschobene_renditen", "series_shift_return mit benannter Verschiebung, Kursen unsortiert, ohne Datum", vor = VOR, teile = list(
  ser_named = teil(
    r"(x <- series_shift_return(d, c('us', 'eu'), c(eu = 3, us = 5)); list(data = x, shift = attr(x, 'shift')))",
    r"(x = PL.series_shift_return(d, ['us', 'eu'], pd.Series({'eu': 3, 'us': 5}))
result = {'data': x, 'shift': x.attrs['shift']})",
    r"(x = PL.series_shift_return(d, ["us", "eu"], SL.named("eu" => 3, "us" => 5))
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"]))", inp = ein("planning/ser_named", c("d"))),
  ser_prices_unsorted = teil(
    r"(x <- series_shift_return(prs, 'us', 4, type = 'prices'); list(data = x, shift = attr(x, 'shift')))",
    r"(x = PL.series_shift_return(prs, 'us', 4, type='prices')
result = {'data': x, 'shift': x.attrs['shift']})",
    r"(x = PL.series_shift_return(prs, "us", 4; type = "prices")
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"]))", inp = ein("planning/ser_prices_unsorted", c("prs"))),
  ser_nodate = teil(
    r"(x <- series_shift_return(d[, c('us', 'eu')], 'eu', 2); list(data = x, shift = attr(x, 'shift')))",
    r"(x = PL.series_shift_return(d[['us', 'eu']], 'eu', 2)
result = {'data': x, 'shift': x.attrs['shift']})",
    r"(x = PL.series_shift_return(SL.RFrame("us" => d.us, "eu" => d.eu), "eu", 2)
result = SL.RList("data" => x, "shift" => SL.attrs(x)["shift"]))", inp = ein("planning/ser_nodate", c("d")))))
SZ("gepoolter_bootstrap", "bootstrap_pooled Standard, unbenannte Gewichte, Ziel (unbenannt und benannt)", vor = VOR, teile = list(
  pb_default = teil(
    r"(bootstrap_pooled(ds, 'aktien', n = 20, seed = 2))",
    r"(result = PL.bootstrap_pooled(ds, 'aktien', n=20, seed=2))",
    r"(result = PL.bootstrap_pooled(ds, "aktien"; n = 20, seed = 2))", inp = ein("planning/pb_default", c("ds"))),
  pb_unnamed_w = teil(
    r"(bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = c(3, 1), n = 10, years = 12, L = 2.5, country_weights = c(1, 2, 1), seed = 3))",
    r"(result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=[3, 1], n=10, years=12, L=2.5, country_weights=[1, 2, 1], seed=3))",
    r"(result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = [3, 1], n = 10, years = 12, L = 2.5, country_weights = [1, 2, 1], seed = 3))", inp = ein("planning/pb_unnamed_w", c("ds"))),
  pb_target = teil(
    r"(bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = c(anleihen = 0.5, aktien = 0.5), n = 15, years = 20, L = 4, target = 4, inflation = 'cpi', seed = 4))",
    r"(result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=pd.Series({'anleihen': 0.5, 'aktien': 0.5}), n=15, years=20, L=4, target=4, inflation='cpi', seed=4))",
    r"(result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = SL.named("anleihen" => 0.5, "aktien" => 0.5), n = 15, years = 20, L = 4, target = 4, inflation = "cpi", seed = 4))", inp = ein("planning/pb_target", c("ds"))),
  pb_target_named = teil(
    r"(bootstrap_pooled(ds, c('aktien', 'anleihen'), n = 15, years = 10, L = 3, target = c(aktien = 5), seed = 5))",
    r"(result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], n=15, years=10, L=3, target=pd.Series({'aktien': 5}), seed=5))",
    r"(result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; n = 15, years = 10, L = 3, target = SL.named("aktien" => 5), seed = 5))", inp = ein("planning/pb_target_named", c("ds")))))
SZ("portfoliorenditen", "portfolio_returns je Quartal und monatlich mit Gold", vor = VOR, teile = list(
  pr_quarter = teil(
    r"(portfolio_returns(pd0, cand, 'quarter'))",
    r"(cand = {k: pd.Series(v) for k, v in cand.items()}
result = PL.portfolio_returns(pd0, cand, frequency='quarter'))",
    r"(result = PL.portfolio_returns(pd0, cand; frequency = "quarter"))", inp = ein("planning/pr_quarter", c("pd0", "cand"))),
  pr_month_gold = teil(
    r"(portfolio_returns(pd0, list(c(gold = 1, aktien = 1), c(anleihen = 2)), frequency = 'month'))",
    r"(result = PL.portfolio_returns(pd0, [pd.Series({'gold': 1, 'aktien': 1}), pd.Series({'anleihen': 2})], frequency='month'))",
    r"(result = PL.portfolio_returns(pd0, Any[SL.named("gold" => 1.0, "aktien" => 1.0), SL.named("anleihen" => 2.0)]; frequency = "month"))", inp = ein("planning/pr_month_gold", c("pd0")))))
SZ("zielplanung", "planning_goal mit Beispiel (Grafikdaten), Matrix ohne Namen und Tabelle", vor = VOR, teile = list(
  go_ex = teil(
    r"(planning_goal(R, start_value = 100000, goal = 150000, horizon = 6, contributions = 2000, n_grid = 41, n_sim = 400, seed = 1))",
    r"(result = PL.planning_goal(R, start_value=100000, goal=150000, horizon=6, contributions=2000, n_grid=41, n_sim=400, seed=1))",
    r"(result = PL.planning_goal(R, 100000, 150000, 6; contributions = 2000, n_grid = 41, n_sim = 400, seed = 1))", druck = TRUE, inp = ein("planning/go_ex", c("R"))),
  go_noname = teil(
    r"(planning_goal(unname(R[1:50, 2:3]), 100, 130, 3, n_grid = 15, n_sim = 100, seed = 4))",
    r"(result = PL.planning_goal(R.to_numpy()[:50, 1:3], 100, 130, 3, n_grid=15, n_sim=100, seed=4))",
    r"(result = PL.planning_goal(R.data[1:50, 2:3], 100, 130, 3; n_grid = 15, n_sim = 100, seed = 4))", druck = TRUE, inp = ein("planning/go_noname", c("R"))),
  go_df = teil(
    r"(planning_goal(as.data.frame(R[1:30, ]), 100, 110, 1, n_grid = 8, n_sim = 60, seed = 6))",
    r"(result = PL.planning_goal(R.iloc[:30], 100, 110, 1, n_grid=8, n_sim=60, seed=6))",
    r"(result = PL.planning_goal(SL.RFrame(R.colnames, [R.data[1:30, j] for j in 1:3]), 100, 110, 1; n_grid = 8, n_sim = 60, seed = 6))", druck = TRUE, inp = ein("planning/go_df", c("R")))))
ref_done()

ref_init("planning", gruppe = "fehler")
TB("series_shift_return", "Meldungen und Warnungen von series_shift_return je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ser_err_df",
    r"(series_shift_return(as.matrix(d[, 2:3]), 'us', 4))",
    r"(result = PL.series_shift_return(d[['us', 'eu']].to_numpy(), 'us', 4))",
    r"(result = PL.series_shift_return(hcat(d.us, d.eu), "us", 4))", inp = ein("planning/ser_err_df", c("d"))),
  zeile("ser_err_col",
    r"(series_shift_return(d, c('us', 'jp', 'cn'), 4))",
    r"(result = PL.series_shift_return(d, ['us', 'jp', 'cn'], 4))",
    r"(result = PL.series_shift_return(d, ["us", "jp", "cn"], 4))", inp = ein("planning/ser_err_col", c("d"))),
  zeile("ser_err_target",
    r"(series_shift_return(d, 'us', '4'))",
    r"(result = PL.series_shift_return(d, 'us', '4'))",
    r"(result = PL.series_shift_return(d, "us", "4"))", inp = ein("planning/ser_err_target", c("d"))),
  zeile("ser_err_named",
    r"(series_shift_return(data.frame(us = rep(1.001, 10), eu = 1.001), c('us', 'eu'), c(us = 4)))",
    r"(result = PL.series_shift_return(pd.DataFrame({'us': np.repeat(1.001, 10), 'eu': 1.001}), ['us', 'eu'], pd.Series({'us': 4})))",
    r"(result = PL.series_shift_return(SL.RFrame("us" => fill(1.001, 10), "eu" => fill(1.001, 10)), ["us", "eu"], SL.named("us" => 4)))", inp = ein("planning/ser_err_named", c())),
  zeile("ser_err_dup",
    r"(series_shift_return(rbind(pr[1:10, ], pr[5, ]), 'us', 4, type = 'prices'))",
    r"(result = PL.series_shift_return(pd.concat([pr.iloc[:10], pr.iloc[[4]]]), 'us', 4, type='prices'))",
    r"(result = PL.series_shift_return(SL.rows(pr, [1:10; 5]), "us", 4; type = "prices"))", inp = ein("planning/ser_err_dup", c("pr")))))
TB("bootstrap_pooled", "Meldungen und Warnungen von bootstrap_pooled je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("pb_err_names",
    r"(bootstrap_pooled(unname(ds), 'aktien', n = 5))",
    r"(result = PL.bootstrap_pooled(list(ds.values()), 'aktien', n=5))",
    r"(result = PL.bootstrap_pooled(collect(values(ds)), "aktien"; n = 5))", inp = ein("planning/pb_err_names", c("ds"))),
  zeile("pb_err_w_neg",
    r"(bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = c(1, -1), n = 5))",
    r"(result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=[1, -1], n=5))",
    r"(result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = [1, -1], n = 5))", inp = ein("planning/pb_err_w_neg", c("ds"))),
  zeile("pb_err_w_names",
    r"(bootstrap_pooled(ds, c('aktien', 'anleihen'), weights = c(aktien = 0.6, bonds = 0.4), n = 5, L = 5, seed = 1))",
    r"(result = PL.bootstrap_pooled(ds, ['aktien', 'anleihen'], weights=pd.Series({'aktien': 0.6, 'bonds': 0.4}), n=5, L=5, seed=1))",
    r"(result = PL.bootstrap_pooled(ds, ["aktien", "anleihen"]; weights = SL.named("aktien" => 0.6, "bonds" => 0.4), n = 5, L = 5, seed = 1))", inp = ein("planning/pb_err_w_names", c("ds"))),
  zeile("pb_err_few",
    r"(bootstrap_pooled(list(a = ds$de[1:2, ], b = ds$us), 'aktien', n = 5))",
    r"(result = PL.bootstrap_pooled({'a': ds['de'].iloc[:2], 'b': ds['us']}, 'aktien', n=5))",
    r"(result = PL.bootstrap_pooled(SL.RList("a" => SL.rows(ds.de, 1:2), "b" => ds.us), "aktien"; n = 5))", inp = ein("planning/pb_err_few", c("ds"))),
  zeile("pb_err_freq",
    r"(bootstrap_pooled(ds, 'aktien', frequency = 'week'))",
    r"(result = PL.bootstrap_pooled(ds, 'aktien', frequency='week'))",
    r"(result = PL.bootstrap_pooled(ds, "aktien"; frequency = "week"))", inp = ein("planning/pb_err_freq", c("ds")))))
TB("planning_goal", "Meldungen und Warnungen von planning_goal je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("go_warn",
    r"(planning_goal(S5, 100, 123.4, 4, n_grid = 301, n_sim = 3000, seed = 1))",
    r"(result = PL.planning_goal(S5, 100, 123.4, 4, n_grid=301, n_sim=3000, seed=1))",
    r"(result = PL.planning_goal(S5, 100, 123.4, 4; n_grid = 301, n_sim = 3000, seed = 1))", print = TRUE, inp = ein("planning/go_warn", c("S5"))),
  zeile("go_err_R",
    r"(planning_goal(-R, 1, 2, 3))",
    r"(result = PL.planning_goal(-R, 1, 2, 3))",
    r"(result = PL.planning_goal(-R.data, 1, 2, 3))", inp = ein("planning/go_err_R", c("R"))),
  zeile("go_err_start",
    r"(planning_goal(R, 0, 1e5, 10))",
    r"(result = PL.planning_goal(R, 0, 1e5, 10))",
    r"(result = PL.planning_goal(R, 0, 1e5, 10))", inp = ein("planning/go_err_start", c("R"))),
  zeile("go_err_goal",
    r"(planning_goal(R, 1e5, -1, 10))",
    r"(result = PL.planning_goal(R, 1e5, -1, 10))",
    r"(result = PL.planning_goal(R, 1e5, -1, 10))", inp = ein("planning/go_err_goal", c("R"))),
  zeile("go_err_h0",
    r"(planning_goal(R, 1e5, 1.5e5, 0))",
    r"(result = PL.planning_goal(R, 1e5, 1.5e5, 0))",
    r"(result = PL.planning_goal(R, 1e5, 1.5e5, 0))", inp = ein("planning/go_err_h0", c("R"))),
  zeile("go_err_grid",
    r"(planning_goal(R, 1e5, 1.5e5, 2, n_grid = 1))",
    r"(result = PL.planning_goal(R, 1e5, 1.5e5, 2, n_grid=1))",
    r"(result = PL.planning_goal(R, 1e5, 1.5e5, 2; n_grid = 1))", inp = ein("planning/go_err_grid", c("R"))),
  zeile("go_err_sim",
    r"(planning_goal(R, 1e5, 1.5e5, 2, n_sim = 0))",
    r"(result = PL.planning_goal(R, 1e5, 1.5e5, 2, n_sim=0))",
    r"(result = PL.planning_goal(R, 1e5, 1.5e5, 2; n_sim = 0))", inp = ein("planning/go_err_sim", c("R"))),
  zeile("go_err_cf0",
    r"(planning_goal(R, 1e5, 1.5e5, 2, contributions = numeric(0)))",
    r"(result = PL.planning_goal(R, 1e5, 1.5e5, 2, contributions=[]))",
    r"(result = PL.planning_goal(R, 1e5, 1.5e5, 2; contributions = Float64[]))", inp = ein("planning/go_err_cf0", c("R")))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul scenarios
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev import scenarios as SC\n"
J <- 'SC = SL.Scenarios\n'
EIN[["scenarios/view_err2"]] <- list()
EIN[["scenarios/view_err3"]] <- list()
EIN[["scenarios/view_err4"]] <- list()
EIN[["scenarios/view_err6"]] <- list()
# ── scenario_entropy_pooling ──────────────────────────────────────────────────────
set.seed(1); X <- data.frame(a = rnorm(400, 0.2, 2), b = rnorm(400, 0.05, 0.5)); X$b <- X$b + 0.1 * X$a
EI <- list(X = X)
# Kursdaten mit Zuständen
set.seed(2); n <- 383   # bis 1.4.1 n <- 3 * 365 (kürzer, Abdeckung gleich)
d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
e <- rnorm(n)
d$aktien <- 100 * cumprod(1 + 0.01 * e)
d$anleihen <- 100 * cumprod(1 + 0.004 * (0.3 * e + rnorm(n)))
d$gold <- 100 * cumprod(1 + 0.008 * rnorm(n))
d$inflation <- 2 + cumsum(rnorm(n, 0, 0.05))
d$aktien[c(30, 31)] <- NA
DI <- list(d = d)
# view_prob: Ausdrücke in R-Syntax (gemeinsamer Auswerter, Modul rexpr); freie Variablen global (R: parent.frame() von scenario_entropy_pooling)
EPV <- c("a < -2 | !b > 0", "abs(a) > 2 * sd(a)", "a > quantile(a, 0.9)", "if (lim > 1) b > 0.5 else FALSE", "(a %/% 1) %% 2 == 0",
         "ifelse(a > 0, \"1\", \"0\")", "a > 0 &\n b > 0")
epq <- function(x) paste0("'", gsub("\n", "\\n", x, fixed = TRUE), "'")
epj <- function(x) paste0('"', gsub("\n", "\\n", gsub('"', '\\"', x, fixed = TRUE), fixed = TRUE), '"')
EPO <- c("=", "<=", "=", "=", ">=", "=", "=")
EPP <- c(0.6, 0.1, 0.15, 0.2, 0.4, 0.5, 0.3)
for (k in seq_along(EPV)) EIN[[paste0("scenarios/", sprintf("ep_rx_%02d", k))]] <- EI
for (k in seq_along(EPE <- c("a < ", "zz > 0", "a[1] > 0", "a > \"x\""))) EIN[[paste0("scenarios/", sprintf("ep_rx_err%d", 
    k))]] <- EI
set.seed(7); XS <- data.frame(x = rnorm(150), y = rnorm(150)); XS$z <- XS$x + 1e-9 * rnorm(150)
EIN[["scenarios/cs_table_psd"]] <- list(XS = XS)
JST <- c("1" = "[[0, 0.1]]", "2" = "(zz = [0, 0.1],)", "3" = "(x = [0.2, 0.1],)", "4" = "(x = [0, 5],)", "5" = "(x = 0.1,)",
         "6" = "SL.RList()", "7" = "(x = [SL.NA, 0.1],)")
for (st in list(c("1", "list(c(0, 0.1))", "[[0, 0.1]]"), c("2", "list(zz = c(0, 0.1))", "{'zz': [0, 0.1]}"), c("3", "list(x = c(0.2, 0.1))", 
    "{'x': [0.2, 0.1]}"), c("4", "list(x = c(0, 5))", "{'x': [0, 5]}"), c("5", "list(x = 0.1)", "{'x': 0.1}"), c("6", "list()", 
    "{}"), c("7", "list(x = c(NA, 0.1))", "{'x': [simlev._r.fmt.NA_REAL, 0.1]}"))) EIN[[paste0("scenarios/", paste0("cs_err", 
    st[1]))]] <- list(XS = XS)
PE <- paste0(P, "ep = SC.scenario_entropy_pooling(X, ['a', 'b'], [])\n")
JE <- paste0(J, 'ep = SC.scenario_entropy_pooling(X, ["a", "b"], [])\n')
EIN[["scenarios/risk_err1"]] <- list()
# ── scenario_crisis ────────────────────────────────────────────────────────
set.seed(3); n <- 1095   # bis 1.4.1 n <- 6 * 365 (kürzer, Abdeckung gleich)
dc <- data.frame(date = seq.Date(as.Date("2006-06-01"), by = "day", length.out = n))
dc$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.012)); dc$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
dc$aktien[c(500, 501)] <- NA
CI <- list(dc = dc)
kr <- data.frame(crisis = c("A", "B", "C", "D"), start = as.Date(c("2007-05-01", "2008-01-01", "2012-05-01", "2001-01-01")),
                 end = as.Date(c("2007-09-30", "2008-01-01", "2012-05-30", "2001-06-01")))
EIN[["scenarios/crisis_custom"]] <- list(dc = dc, kr = kr)
dlate <- dc[dc$date >= as.Date("2008-01-10"), ]
EIN[["scenarios/crisis_chr"]] <- list(dlate = dlate)
EIN[["scenarios/crisis_err1"]] <- list(dc = dc[1:5, ])
EIN[["scenarios/crisis_err2"]] <- list(dc = dc[1:5, ])
EIN[["scenarios/crisis_err4"]] <- list(dc = dc[1:5, ])
EIN[["scenarios/crisis_err5"]] <- list(dc = dc[1:5, ])
EIN[["scenarios/crisis_err6"]] <- list(dc = dc[1:50, ])
EIN[["scenarios/crisis_err7"]] <- list(dc = dc[1:5, ])

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import scenarios as SC)",
            jl = r"(SC = SL.Scenarios)")

ref_init("scenarios", gruppe = "gleichlauf")
SZ("entropy_pooling", "scenario_entropy_pooling mit Volatilitäts- und Mittelwert-Sicht, Prior, Matrix, Wahrscheinlichkeits-Sicht in R-Syntax; scenario_risk", vor = VOR, teile = list(
  ep_vol_mean = teil(
    r"(scenario_entropy_pooling(X, c('a', 'b'), list(view_vol('a', 1.5), view_mean('a', 0.5), view_mean('b', 0, '>=')), frequency = 'month'))",
    r"(result = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_vol('a', 1.5), SC.view_mean('a', 0.5), SC.view_mean('b', 0, op='>=')], frequency='month'))",
    r"(result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_vol("a", 1.5), SC.view_mean("a", 0.5), SC.view_mean("b", 0, ">=")]; frequency = "month"))", druck = TRUE, inp = ein("scenarios/ep_vol_mean", c("X"))),
  ep_prior = teil(
    r"(scenario_entropy_pooling(X, c('a', 'b'), list(view_mean('b', 0.1)), prior = seq_len(400)))",
    r"(result = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_mean('b', 0.1)], prior=np.arange(1, 401)))",
    r"(result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_mean("b", 0.1)]; prior = collect(1:400)))", druck = TRUE, inp = ein("scenarios/ep_prior", c("X"))),
  ep_matrix = teil(
    r"(scenario_entropy_pooling(unname(as.matrix(X)), c('V1', 'V2'), list(view_mean('V1', 0))))",
    r"(result = SC.scenario_entropy_pooling(X.to_numpy(), ['V1', 'V2'], [SC.view_mean('V1', 0)]))",
    r"(result = SC.scenario_entropy_pooling(Matrix(hcat(X["a"], X["b"])), ["V1", "V2"], [SC.view_mean("V1", 0)]))", druck = TRUE, inp = ein("scenarios/ep_matrix", c("X"))),
  ep_rx_06 = teil(
    r"-(lim <<- 1.5; scenario_entropy_pooling(X, c('a', 'b'), list(view_prob("ifelse(a > 0, \"1\", \"0\")", 0.5, '='))))-",
    r"(lim = 1.5
result = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_prob('ifelse(a > 0, "1", "0")', 0.5, op='=')]))",
    r"-(lim = 1.5; result = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_prob("ifelse(a > 0, \"1\", \"0\")", 0.5, "=")]; env = @__MODULE__))-", druck = TRUE, inp = ein("scenarios/ep_rx_06", c("X"))),
  risk = teil(
    r"(ep <- scenario_entropy_pooling(X, c('a', 'b'), list(view_mean('a', -0.2))); cs <- scenario_copula(X, c('a', 'b'), n = 300, seed = 1)
  list(scenario_risk(ep, c(a = 0.6, b = 0.4)), scenario_risk(ep, c(b = 1), alpha = 0.2), scenario_risk(cs, c(a = 0.5, b = 0.5), 0.01)))",
    r"(ep = SC.scenario_entropy_pooling(X, ['a', 'b'], [SC.view_mean('a', -0.2)]); cs = SC.scenario_copula(X, ['a', 'b'], n=300, seed=1)
result = [SC.scenario_risk(ep, {'a': 0.6, 'b': 0.4}), SC.scenario_risk(ep, pd.Series({'b': 1.0}), alpha=0.2), SC.scenario_risk(cs, {'a': 0.5, 'b': 0.5}, alpha=0.01)])",
    r"(ep = SC.scenario_entropy_pooling(X, ["a", "b"], [SC.view_mean("a", -0.2)]); cs = SC.scenario_copula(X, ["a", "b"]; n = 300, seed = 1)
result = [SC.scenario_risk(ep, SL.named("a" => 0.6, "b" => 0.4)), SC.scenario_risk(ep, SL.named("b" => 1.0); alpha = 0.2), SC.scenario_risk(cs, (a = 0.5, b = 0.5); alpha = 0.01)])", inp = ein("scenarios/risk", c("X")))))
SZ("copula_szenarien", "scenario_copula gaussian mit Stress, Stress auf zwei Reihen, Tabelle mit nicht positiv definiter Korrelation", vor = VOR, teile = list(
  cs_stress1g = teil(
    r"(scenario_copula(d, c('aktien', 'anleihen'), n = 200, family = 'gaussian', stress = list(anleihen = c(0.9, 1)), seed = 4))",
    r"(result = SC.scenario_copula(d, ['aktien', 'anleihen'], n=200, family='gaussian', stress={'anleihen': [0.9, 1]}, seed=4))",
    r"(result = SC.scenario_copula(d, ["aktien", "anleihen"]; n = 200, family = "gaussian", stress = (anleihen = [0.9, 1],), seed = 4))", druck = TRUE, inp = ein("scenarios/cs_stress1g", c("d"))),
  cs_stress2 = teil(
    r"(scenario_copula(d, c('aktien', 'anleihen', 'gold'), n = 100, stress = list(gold = c(0, 0.3), aktien = c(0, 0.3)), seed = 5))",
    r"(result = SC.scenario_copula(d, ['aktien', 'anleihen', 'gold'], n=100, stress={'gold': [0, 0.3], 'aktien': [0, 0.3]}, seed=5))",
    r"(result = SC.scenario_copula(d, ["aktien", "anleihen", "gold"]; n = 100, stress = (gold = [0, 0.3], aktien = [0, 0.3]), seed = 5))", druck = TRUE, inp = ein("scenarios/cs_stress2", c("d"))),
  cs_table_psd = teil(
    r"(scenario_copula(XS, c('x', 'y', 'z'), n = 200, seed = 8))",
    r"(result = SC.scenario_copula(XS, ['x', 'y', 'z'], n=200, seed=8))",
    r"(result = SC.scenario_copula(XS, ["x", "y", "z"]; n = 200, seed = 8))", druck = TRUE, inp = ein("scenarios/cs_table_psd", c("XS")))))
SZ("krisen", "scenario_crisis mit eigener Krisentabelle (Umschichten) und Datum als Text", vor = VOR, teile = list(
  crisis_custom = teil(
    r"(list(scenario_crisis(dc, c(aktien = 3, anleihen = 1), kr, rebalance = TRUE), scenario_crisis(dc, c(anleihen = 1), kr)))",
    r"(result = [SC.scenario_crisis(dc, {'aktien': 3, 'anleihen': 1}, crises=kr, rebalance=True), SC.scenario_crisis(dc, {'anleihen': 1}, crises=kr)])",
    r"(result = [SC.scenario_crisis(dc, (aktien = 3, anleihen = 1), kr; rebalance = true), SC.scenario_crisis(dc, (anleihen = 1,), kr)])", inp = ein("scenarios/crisis_custom", c("dc", "kr"))),
  crisis_chr = teil(
    r"(kc <- data.frame(crisis = 'X', start = '2009-01-05', end = '2010-02-01'); scenario_crisis(dlate[c(2, 1, 3:nrow(dlate)), ], c(aktien = 0.5, anleihen = 0.5), kc))",
    r"(kc = pd.DataFrame({'crisis': ['X'], 'start': ['2009-01-05'], 'end': ['2010-02-01']}); result = SC.scenario_crisis(dlate.iloc[[1, 0] + list(range(2, len(dlate)))], {'aktien': 0.5, 'anleihen': 0.5}, crises=kc))",
    r"(kc = SL.RFrame("crisis" => ["X"], "start" => ["2009-01-05"], "end" => ["2010-02-01"]); result = SC.scenario_crisis(SL.rows(dlate, vcat([2, 1], 3:SL.nrow(dlate))), (aktien = 0.5, anleihen = 0.5), kc))", inp = ein("scenarios/crisis_chr", c("dlate")))))
# NaN und später NA im Fenster der Krise A (seit 1.6.3 rechnet Julia cummax wie R und Python; ohne Zufall aus dc)
dcl <- dc; dcl$anleihen[400] <- NaN; dcl$aktien[c(420, 421)] <- NA
SZ("krisen_mit_luecken", "scenario_crisis mit NaN und später NA in den Kursen innerhalb einer Krise (LOCF), mit und ohne Umschichten", vor = VOR, teile = list(
  crisis_gap = teil(
    r"(list(scenario_crisis(dcl, c(aktien = 0.5, anleihen = 0.5), kr), scenario_crisis(dcl, c(aktien = 0.5, anleihen = 0.5), kr, rebalance = TRUE)))",
    r"(result = [SC.scenario_crisis(dcl, {'aktien': 0.5, 'anleihen': 0.5}, crises=kr), SC.scenario_crisis(dcl, {'aktien': 0.5, 'anleihen': 0.5}, crises=kr, rebalance=True)])",
    r"(result = [SC.scenario_crisis(dcl, (aktien = 0.5, anleihen = 0.5), kr), SC.scenario_crisis(dcl, (aktien = 0.5, anleihen = 0.5), kr; rebalance = true)])", inp = list(dcl = dcl, kr = kr))))
ref_done()

ref_init("scenarios", gruppe = "fehler")
TB("view_prob", "Meldungen und Warnungen von view_prob je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("view_err2",
    r"(view_prob('a > 1', 1.5))",
    r"(result = SC.view_prob('a > 1', 1.5))",
    r"(result = SC.view_prob("a > 1", 1.5))", inp = ein("scenarios/view_err2", c()))))
TB("view_vol", "Meldungen und Warnungen von view_vol je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("view_err3",
    r"(view_vol('a', -1))",
    r"(result = SC.view_vol('a', -1))",
    r"(result = SC.view_vol("a", -1))", inp = ein("scenarios/view_err3", c()))))
TB("view_mean", "Meldungen und Warnungen von view_mean je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("view_err4",
    r"(view_mean('a', c(1, 2)))",
    r"(result = SC.view_mean('a', [1, 2]))",
    r"(result = SC.view_mean("a", [1, 2]))", inp = ein("scenarios/view_err4", c())),
  zeile("view_err6",
    r"(view_mean('a', 1, '=='))",
    r"(result = SC.view_mean('a', 1, op='=='))",
    r"(result = SC.view_mean("a", 1, "=="))", inp = ein("scenarios/view_err6", c()))))
TB("scenario_entropy_pooling", "Meldungen und Warnungen von scenario_entropy_pooling je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ep_err_prior3",
    r"(scenario_entropy_pooling(X, 'a', list(), prior = rep(0, 400)))",
    r"(result = SC.scenario_entropy_pooling(X, 'a', [], prior=np.zeros(400)))",
    r"(result = SC.scenario_entropy_pooling(X, "a", []; prior = zeros(400)))", inp = ein("scenarios/ep_err_prior3", c("X"))),
  zeile("ep_err_view3",
    r"(scenario_entropy_pooling(X, 'a', list(view_vol('zz', 1))))",
    r"(result = SC.scenario_entropy_pooling(X, 'a', [SC.view_vol('zz', 1)]))",
    r"(result = SC.scenario_entropy_pooling(X, "a", [SC.view_vol("zz", 1)]))", inp = ein("scenarios/ep_err_view3", c("X"))),
  zeile("ep_err_view4",
    r"(scenario_entropy_pooling(X, 'a', list(list(type = 'skew', var = 'a', value = 1, op = '='))))",
    r"(result = SC.scenario_entropy_pooling(X, 'a', [{'type': 'skew', 'var': 'a', 'value': 1, 'op': '='}]))",
    r"(result = SC.scenario_entropy_pooling(X, "a", [SL.RList("type" => "skew", "var" => "a", "value" => 1, "op" => "=")]))", inp = ein("scenarios/ep_err_view4", c("X"))),
  zeile("ep_rx_err4",
    r"(scenario_entropy_pooling(X, 'a', list(view_prob("a > \"x\"", 0.5))))",
    r"(result = SC.scenario_entropy_pooling(X, 'a', [SC.view_prob('a > "x"', 0.5)]))",
    r"(result = SC.scenario_entropy_pooling(X, "a", [SC.view_prob("a > \"x\"", 0.5)]))", print = TRUE, inp = ein("scenarios/ep_rx_err4", c("X"))),
  zeile("risk_err2",
    r"(ep <- scenario_entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(a = 1), alpha = 1))",
    r"(ep = SC.scenario_entropy_pooling(X, ['a', 'b'], [])
result = SC.scenario_risk(ep, {'a': 1}, alpha=1))",
    r"(ep = SC.scenario_entropy_pooling(X, ["a", "b"], [])
result = SC.scenario_risk(ep, (a = 1,); alpha = 1))", inp = ein("scenarios/risk_err2", c("X"))),
  zeile("risk_err3",
    r"(ep <- scenario_entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(1, 2)))",
    r"(ep = SC.scenario_entropy_pooling(X, ['a', 'b'], [])
result = SC.scenario_risk(ep, [1, 2]))",
    r"(ep = SC.scenario_entropy_pooling(X, ["a", "b"], [])
result = SC.scenario_risk(ep, [1, 2]))", inp = ein("scenarios/risk_err3", c("X"))),
  zeile("risk_err4",
    r"(ep <- scenario_entropy_pooling(X, c('a', 'b'), list()); scenario_risk(ep, c(a = 1, q = 2)))",
    r"(ep = SC.scenario_entropy_pooling(X, ['a', 'b'], [])
result = SC.scenario_risk(ep, {'a': 1, 'q': 2}))",
    r"(ep = SC.scenario_entropy_pooling(X, ["a", "b"], [])
result = SC.scenario_risk(ep, (a = 1, q = 2)))", inp = ein("scenarios/risk_err4", c("X")))))
TB("scenario_copula", "Meldungen und Warnungen von scenario_copula je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("cs_err1",
    r"(scenario_copula(XS, c('x', 'y'), n = 10, family = 'gaussian', stress = list(c(0, 0.1))))",
    r"(result = SC.scenario_copula(XS, ['x', 'y'], n=10, family='gaussian', stress=[[0, 0.1]]))",
    r"(result = SC.scenario_copula(XS, ["x", "y"]; n = 10, family = "gaussian", stress = [[0, 0.1]]))", inp = ein("scenarios/cs_err1", c("XS"))),
  zeile("cs_err2",
    r"(scenario_copula(XS, c('x', 'y'), n = 10, family = 'gaussian', stress = list(zz = c(0, 0.1))))",
    r"(result = SC.scenario_copula(XS, ['x', 'y'], n=10, family='gaussian', stress={'zz': [0, 0.1]}))",
    r"(result = SC.scenario_copula(XS, ["x", "y"]; n = 10, family = "gaussian", stress = (zz = [0, 0.1],)))", inp = ein("scenarios/cs_err2", c("XS"))),
  zeile("cs_err5",
    r"(scenario_copula(XS, c('x', 'y'), n = 10, family = 'gaussian', stress = list(x = 0.1)))",
    r"(result = SC.scenario_copula(XS, ['x', 'y'], n=10, family='gaussian', stress={'x': 0.1}))",
    r"(result = SC.scenario_copula(XS, ["x", "y"]; n = 10, family = "gaussian", stress = (x = 0.1,)))", inp = ein("scenarios/cs_err5", c("XS")))))
TB("scenario_risk", "Meldungen und Warnungen von scenario_risk je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("risk_err1",
    r"(scenario_risk(list(), c(a = 1)))",
    r"(result = SC.scenario_risk({}, {'a': 1}))",
    r"(result = SC.scenario_risk(SL.RList(), (a = 1,)))", inp = ein("scenarios/risk_err1", c()))))
TB("scenario_crisis", "Meldungen und Warnungen von scenario_crisis je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("crisis_err1",
    r"(scenario_crisis(as.matrix(dc[, -1]), c(aktien = 1)))",
    r"(result = SC.scenario_crisis(dc.iloc[:, 1:].to_numpy(), {'aktien': 1}))",
    r"(result = SC.scenario_crisis(hcat(dc["aktien"], dc["anleihen"]), (aktien = 1,)))", inp = ein("scenarios/crisis_err1", c("dc"))),
  zeile("crisis_err2",
    r"(scenario_crisis(dc, c(aktien = 1), data.frame(a = 1)))",
    r"(result = SC.scenario_crisis(dc, {'aktien': 1}, crises=pd.DataFrame({'a': [1]})))",
    r"(result = SC.scenario_crisis(dc, (aktien = 1,), SL.RFrame("a" => [1])))", inp = ein("scenarios/crisis_err2", c("dc"))),
  zeile("crisis_err4",
    r"(scenario_crisis(dc, c(aktien = 1, zz = 1)))",
    r"(result = SC.scenario_crisis(dc, {'aktien': 1, 'zz': 1}))",
    r"(result = SC.scenario_crisis(dc, (aktien = 1, zz = 1)))", inp = ein("scenarios/crisis_err4", c("dc"))),
  zeile("crisis_err5",
    r"(scenario_crisis(dc, c(aktien = 1, anleihen = -1.5)))",
    r"(result = SC.scenario_crisis(dc, {'aktien': 1, 'anleihen': -1.5}))",
    r"(result = SC.scenario_crisis(dc, (aktien = 1, anleihen = -1.5)))", inp = ein("scenarios/crisis_err5", c("dc"))),
  zeile("crisis_err6",
    r"(scenario_crisis(dc, c(aktien = 1)))",
    r"(result = SC.scenario_crisis(dc, {'aktien': 1}))",
    r"(result = SC.scenario_crisis(dc, (aktien = 1,)))", inp = ein("scenarios/crisis_err6", c("dc"))),
  zeile("crisis_err7",
    r"(scenario_crisis(dc, c(0.5, 0.5)))",
    r"(result = SC.scenario_crisis(dc, [0.5, 0.5]))",
    r"(result = SC.scenario_crisis(dc, [0.5, 0.5]))", inp = ein("scenarios/crisis_err7", c("dc")))))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul tactical
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev import tactical as T\nimport numpy as np, pandas as pd, math\n"
J <- "T = SL.Tactical\n"   # Kopf des Julia-Codes (jl)
make_mkt <- function(n = 1022, seed = 1) {   # bis 1.4.1 n = 365 * 4 (kürzer, Abdeckung gleich)
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
EIN[["tactical/ss_none"]] <- I
dme <- data.frame(date = seq.Date(as.Date("2019-01-01"), as.Date("2021-12-31"), by = "day"))
dme$A <- as.numeric(dme$date - dme$date[1]) + 100
wd <- d[!format(d$date, "%u") %in% c("6", "7"), c("date", "A", "B")]
EIN[["tactical/ms_posixct"]] <- I
EIN[["tactical/ms_err_miss"]] <- I
# ── tactical_rules: Bedingungen als Text in R-Syntax (gemeinsamer Auswerter, Modul rexpr) ──
qpy <- function(x) paste0('"', gsub('"', '\\"', gsub("\n", "\\n", gsub("\\", "\\\\", x, fixed = TRUE), fixed = TRUE), fixed = TRUE), '"')
qjl <- function(x) paste0('"', gsub("$", "\\$", gsub('"', '\\"', gsub("\n", "\\n", gsub("\\", "\\\\", x, fixed = TRUE), fixed = TRUE), fixed = TRUE), fixed = TRUE), '"')
TRX <- c("!A > B", "A > B & !infl > 2.2", "infl %in% c(2, 2.05, 2.1)", "A > mean(A)", "A > quantile(A, 0.8)",
         "date >= as.Date('2013-06-01') & date < as.Date('2014-01-01')", "(A %/% 5) %% 2 == 0", "A > 105 & NA",
         "A > max(A) - 10 | B < min(B) + 2", "infl > c(2, 2.2)", "cumsum(A > 110) > 0", "abs(A - B) < 5",
         "sqrt(A) > 10.2", "log(A / B) > 0.05", "is.na(infl) | infl > 2.3", "\"TRUE\"", "ifelse(A > B, 1, 0)",
         "as.character(A > B)", "A > B\n& infl > 2", "A > ", "A >> B", "Z > 1", "A > B && infl > 2",
         "TRUE + (A > 100) == 2L", "A[-1] > A[-length(A)]", "{a <- A / B; a > 1.05}", "A > B # Kommentar",
         "date > \"2014-03-01\"", "infl == 2 | infl == 2.25", "!(A > B | B > C)")
for (k in seq_along(TRX)) EIN[[paste0("tactical/", sprintf("tr_rx_%02d", k))]] <- I
EIN[["tactical/rot_breadth"]] <- I
EIN[["tactical/rot_invvol"]] <- I
EIN[["tactical/rot_err_safe"]] <- I
EIN[["tactical/rot_err_top"]] <- I
EIN[["tactical/rot_err_breadth"]] <- I
EIN[["tactical/rot_err_short"]] <- I
EIN[["tactical/tv_safe_in_w"]] <- I
EIN[["tactical/tv_warn"]] <- I
EIN[["tactical/tv_err_kredit"]] <- I
EIN[["tactical/tv_err_miss"]] <- I
EIN[["tactical/tv_err_safe"]] <- I
EIN[["tactical/tv_err_unnamed"]] <- I
EIN[["tactical/tv_err_mismatch"]] <- I
EIN[["tactical/tv_err_short"]] <- I
EIN[["tactical/cv_fixed"]] <- I
EIN[["tactical/cv_msg"]] <- I
EIN[["tactical/cv_target_warn"]] <- I
EIN[["tactical/cv_err_kredit"]] <- I
EIN[["tactical/cv_err_base"]] <- I
EIN[["tactical/cv_err_min"]] <- I
EIN[["tactical/cv_err_upper"]] <- I
EIN[["tactical/cv_err_lower"]] <- I
EIN[["tactical/cv_err_fixed"]] <- I
EIN[["tactical/cv_err_high"]] <- I
EIN[["tactical/cv_err_low"]] <- I
EIN[["tactical/cv_err_short"]] <- I
EIN[["tactical/gp_jump"]] <- I
EIN[["tactical/gp_err"]] <- I
EIN[["tactical/bl_basic"]] <- I
EIN[["tactical/bl_err_shares"]] <- I
EIN[["tactical/bl_err_empty"]] <- I
EIN[["tactical/bl_err_dates"]] <- I
EIN[["tactical/helpers"]] <- I
EIN[["tactical/helpers_err"]] <- I
EIN[["tactical/as_weights_err"]] <- I
# ── tactical_simulation ──────────────────────────────────────────────────────
ds <- make_mkt(365 * 3)[, c("date", "A", "C")]
set.seed(9); b2 <- runif(nrow(ds)) < 0.01; s2 <- runif(nrow(ds)) < 0.01
I3 <- list(ds = ds, b2 = b2, s2 = s2)
cal <- seq.Date(as.Date("2021-01-04"), as.Date("2021-03-31"), by = "day")
wkd <- cal[!format(cal, "%u") %in% c("6", "7")]
set.seed(11); al <- data.frame(date = cal, aktien = NA_real_, geld = 100)
al$aktien[match(wkd, cal)] <- 100 * cumprod(1 + rnorm(length(wkd), 0, 0.01))
fl <- cbind(aktien = is.na(al$aktien), geld = !cal %in% wkd)
al$aktien <- SimLev:::.fill_na(al$aktien, "locf")
I4 <- list(al = al, fl = fl)

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import tactical as T
import numpy as np, pandas as pd, math)",
            jl = r"(T = SL.Tactical)")

ref_init("tactical", gruppe = "gleichlauf")
SZ("signale_und_regeln", "signal_state ohne Signal, POSIXct-Datum, tactical_rules mit R-Syntax und NA, Hilfen .period_last", vor = VOR, teile = list(
  ss_none = teil(
    r"(signal_state(list(buy = c(F, F, F), sell = c(F, F, F))))",
    r"(result = T.signal_state({'buy': [False] * 3, 'sell': [False] * 3}))",
    r"(result = T.signal_state(SL.RList("buy" => fill(false, 3), "sell" => fill(false, 3))))", inp = ein("tactical/ss_none", c("buy", "sell"))),
  ms_posixct = teil(
    r"(x2 <- data.frame(date = as.POSIXct(format(d$date[1:400]), tz = 'Europe/Berlin'), A = d$A[1:400]); momentum_score(x2, 'A', lookbacks = c(1, 2)))",
    r"(x2 = pd.DataFrame({'date': pd.to_datetime(d['date'][:400]).dt.tz_localize('Europe/Berlin'), 'A': d['A'][:400]}); result = T.momentum_score(x2, 'A', lookbacks=[1, 2]))",
    r"(x2 = SL.RFrame("date" => DateTime.(d.date[1:400]), "A" => d.A[1:400]); result = T.momentum_score(x2, "A"; lookbacks = [1, 2]))", inp = ein("tactical/ms_posixct", c("d"))),
  tr_rx_08 = teil(
    r"(attr(tactical_rules(d, list(list(when = "A > 105 & NA", weights = c(A = 1)), list(when = 'B > 100', weights = c(B = 1))), default = c(C = 1)), 'regime'))",
    r"(result = T.tactical_rules(d, [{'when': "A > 105 & NA", 'weights': {'A': 1}}, {'when': 'B > 100', 'weights': {'B': 1}}], default={'C': 1}).attrs['regime'])",
    r"(result = SL.attrs(T.tactical_rules(d, [SL.RList("when" => "A > 105 & NA", "weights" => SL.named("A" => 1)), SL.RList("when" => "B > 100", "weights" => SL.named("B" => 1))], SL.named("C" => 1); env = @__MODULE__))["regime"])", inp = ein("tactical/tr_rx_08", c("d"))),
  helpers = teil(
    r"(dd <- d$date[1:800]; list(SimLev:::.period_last(dd, 'day')[1:5], SimLev:::.period_last(dd, 'week'), SimLev:::.period_last(dd, 'month'),
                SimLev:::.period_last(dd, 'quarter'), SimLev:::.period_last(dd, 'year'),
                SimLev:::.hold_rows(10L, c(3L, 7L), matrix(1:6, 2, dimnames = list(NULL, c('x', 'y', 'z'))))))",
    r"(dd = d['date'].to_numpy()[:800]; result = [T._period_last(dd, 'day')[:5], T._period_last(dd, 'week'), T._period_last(dd, 'month'),
          T._period_last(dd, 'quarter'), T._period_last(dd, 'year'),
          T._hold_rows(10, [3, 7], pd.DataFrame([[1., 3, 5], [2, 4, 6]], columns=['x', 'y', 'z']))])",
    r"(dd = d.date[1:800]; result = [T._period_last(dd, "day")[1:5], T._period_last(dd, "week"), T._period_last(dd, "month"),
          T._period_last(dd, "quarter"), T._period_last(dd, "year"),
          T._hold_rows(10, [3, 7], SL.NamedMat([1.0 3 5; 2 4 6]; colnames = ["x", "y", "z"]))])", inp = ein("tactical/helpers", c("d")))))
SZ("rotation_und_volatilitaet", "tactical_rotation (Breite, inverse Volatilität), tactical_target_volatility mit sicherem Asset in den Gewichten, tactical_conditional_volatility fest und mit Hinweis", vor = VOR, teile = list(
  rot_breadth = teil(
    r"(tactical_rotation(d, c('A', 'B', 'C'), top = 2, safe = 'CASH', canary = c('A', 'B', 'C'), breadth = 2, type = '13612w', every = 'quarter'))",
    r"(result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2, safe='CASH', canary=['A', 'B', 'C'], breadth=2, type='13612w', every='quarter'))",
    r"(result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2, safe = "CASH", canary = ["A", "B", "C"], breadth = 2, type = "13612w", every = "quarter"))", druck = TRUE, inp = ein("tactical/rot_breadth", c("d"))),
  rot_invvol = teil(
    r"(tactical_rotation(d, c('A', 'B', 'C'), top = 2, safe = 'CASH', weighting = 'inverse_vol', lookbacks = c(1, 6)))",
    r"(result = T.tactical_rotation(d, ['A', 'B', 'C'], top=2, safe='CASH', weighting='inverse_vol', lookbacks=[1, 6]))",
    r"(result = T.tactical_rotation(d, ["A", "B", "C"]; top = 2, safe = "CASH", weighting = "inverse_vol", lookbacks = [1, 6]))", druck = TRUE, inp = ein("tactical/rot_invvol", c("d"))),
  tv_safe_in_w = teil(
    r"(tactical_target_volatility(d, c(A = 0.6, CASH = 0.4), safe = 'CASH', target = 20))",
    r"(result = T.tactical_target_volatility(d, pd.Series({'A': 0.6, 'CASH': 0.4}), safe='CASH', target=20))",
    r"(result = T.tactical_target_volatility(d, SL.named("A" => 0.6, "CASH" => 0.4), "CASH"; target = 20))", druck = TRUE, inp = ein("tactical/tv_safe_in_w", c("d"))),
  cv_fixed = teil(
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.7, min_history = 1, scaling = 'fixed', high_exposure = 0.3, low_exposure = 0.9))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.7, min_history=1, scaling='fixed', high_exposure=0.3, low_exposure=0.9))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.7, min_history = 1, scaling = "fixed", high_exposure = 0.3, low_exposure = 0.9))", druck = TRUE, inp = ein("tactical/cv_fixed", c("d"))),
  cv_msg = teil(
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', min_history = 1))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', min_history=1))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; min_history = 1))", druck = TRUE, inp = ein("tactical/cv_msg", c("d")))))
SZ("gleitpfad_und_simulation", "tactical_glidepath mit Sprung, Gleitpfad mit Rotation (Grafikdaten), Kette Gleitpfad und Regeln -> tactical_blend -> tactical_simulation mit Toleranz, Verzögerung und Sparplan, Simulation mit gefüllten Tagen", vor = VOR, teile = list(
  gp_jump = teil(
    r"(tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.4, C = 0.6), start = '2013-06-15', end = '2013-06-15'))",
    r"(result = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.4, 'C': 0.6}, start='2013-06-15', end='2013-06-15'))",
    r"(result = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.4, "C" => 0.6); start = "2013-06-15", end_ = "2013-06-15"))", druck = TRUE, inp = ein("tactical/gp_jump", c("d"))),
  bl_basic = teil(
    r"(gp <- tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.3, C = 0.7)); ro <- tactical_rotation(d, c('A', 'B'), top = 1, safe = c('C', 'CASH'))
   tactical_blend(x = gp, y = ro, shares = c(0.5, 0.5)))",
    r"(gp = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.3, 'C': 0.7}); ro = T.tactical_rotation(d, ['A', 'B'], top=1, safe=['C', 'CASH'])
result = T.tactical_blend(gp, ro, shares=[0.5, 0.5]))",
    r"(gp = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.3, "C" => 0.7)); ro = T.tactical_rotation(d, ["A", "B"]; top = 1, safe = ["C", "CASH"])
result = T.tactical_blend(gp, ro; shares = [0.5, 0.5]))", druck = TRUE, inp = ein("tactical/bl_basic", c("d"))),
  ts_tol_dca = teil(
    r"(ws <- tactical_blend(x = tactical_glidepath(ds, from = c(A = 0.8, C = 0.2), to = c(A = 0.4, C = 0.6), every = 'quarter'), y = tactical_rules(ds, list(list(when = list(buy = b2, sell = s2), weights = c(A = 1))), default = c(A = 0.3, C = 0.7)), shares = c(0.5, 0.5))
   res <- tactical_simulation(ds, ws, rebalance = 'month', tolerance = 5, lag = 2, dca = dca_plan(500, 1, unit = 'quarter'), asset_args = list(spread = 0.1, partial_exemption = c(A = 30, C = 0))); list(tactical = res$tactical, worth = res$worth, dates = res$dates))",
    r"(ws = T.tactical_blend(T.tactical_glidepath(ds, from_={'A': 0.8, 'C': 0.2}, to={'A': 0.4, 'C': 0.6}, every='quarter'), T.tactical_rules(ds, [{'when': {'buy': b2, 'sell': s2}, 'weights': {'A': 1}}], default={'A': 0.3, 'C': 0.7}), shares=[0.5, 0.5])
res = T.tactical_simulation(ds, ws, rebalance='month', tolerance=5, lag=2, dca=simlev.dca_plan(500, 1, unit='quarter'), asset_args={'spread': 0.1, 'partial_exemption': pd.Series({'A': 30, 'C': 0})})
result = {'tactical': res.tactical, 'worth': res.worth, 'dates': res.dates})",
    r"(ws = T.tactical_blend(T.tactical_glidepath(ds, SL.named("A" => 0.8, "C" => 0.2), SL.named("A" => 0.4, "C" => 0.6); every = "quarter"), T.tactical_rules(ds, [SL.RList("when" => SL.RList("buy" => b2, "sell" => s2), "weights" => SL.named("A" => 1))], SL.named("A" => 0.3, "C" => 0.7)); shares = [0.5, 0.5])
res = T.tactical_simulation(ds, ws; rebalance = "month", tolerance = 5, lag = 2, dca = SL.dca_plan(500, 1; unit = "quarter"), asset_args = (spread = 0.1, partial_exemption = SL.named("A" => 30, "C" => 0)))
result = SL.RList("tactical" => res.tactical, "worth" => res.worth, "dates" => res.dates))", inp = ein("tactical/ts_dca", c("ds", "b2", "s2"))),
  ts_filled = teil(
    r"(a2 <- al; attr(a2, 'filled') <- fl
   w <- tactical_rules(a2, list(list(when = a2$date >= as.Date('2021-02-05'), weights = c(aktien = 1))), default = c(geld = 1))
   res <- tactical_simulation(a2, w, lag = 1, asset_args = list(spread = 0)); list(tactical = res$tactical, worth = res$worth, dates = res$dates))",
    r"(a2 = al.copy(); a2.attrs['filled'] = fl
w = T.tactical_rules(a2, [{'when': a2['date'] >= np.datetime64('2021-02-05'), 'weights': {'aktien': 1}}], default={'geld': 1})
res = T.tactical_simulation(a2, w, lag=1, asset_args={'spread': 0})
result = {'tactical': res.tactical, 'worth': res.worth, 'dates': res.dates})",
    r"(a2 = copy(al); SL.attrs(a2)["filled"] = fl
w = T.tactical_rules(a2, [SL.RList("when" => a2.date .>= Date(2021, 2, 5), "weights" => SL.named("aktien" => 1))], SL.named("geld" => 1))
res = T.tactical_simulation(a2, w; lag = 1, asset_args = (spread = 0,))
result = SL.RList("tactical" => res.tactical, "worth" => res.worth, "dates" => res.dates))", inp = ein("tactical/ts_filled", c("al", "fl")))))
ref_done()

SZ("text_logik", "signal_state mit NA (pd.NA bzw. missing) und Zahlen, tactical_rules mit Textvektor als Bedingung (jedes Element ein Ausdruck in R-Syntax, Ergebnis des letzten; seit 1.6.3 in Python und Julia wie R)", vor = VOR, teile = list(
  ss_lgl_na = teil(
    r"(signal_state(list(buy = c(TRUE, NA, FALSE, TRUE), sell = c(FALSE, TRUE, NA, FALSE))))",
    r"(result = T.signal_state({'buy': pd.array([True, pd.NA, False, True], dtype='boolean'), 'sell': pd.array([False, True, pd.NA, False], dtype='boolean')}))",
    r"(result = T.signal_state(SL.RList("buy" => [true, missing, false, true], "sell" => [false, true, missing, false])))", inp = list()),
  ss_num = teil(
    r"(signal_state(list(buy = c(1, 0, NA, 1), sell = c(0, 1, 0, NaN))))",
    r"(result = T.signal_state({'buy': [1.0, 0.0, simlev._r.fmt.NA_REAL, 1.0], 'sell': [0.0, 1.0, 0.0, math.nan]}))",
    r"(result = T.signal_state(SL.RList("buy" => [1.0, 0.0, SL.NA, 1.0], "sell" => [0.0, 1.0, 0.0, NaN])))", inp = list()),
  tr_txtvec = teil(
    r"(attr(tactical_rules(d, list(list(when = c("A > 105", "B > 100"), weights = c(A = 1))), default = c(C = 1)), 'regime'))",
    r"(result = T.tactical_rules(d, [{'when': ['A > 105', 'B > 100'], 'weights': {'A': 1}}], default={'C': 1}).attrs['regime'])",
    r"(result = SL.attrs(T.tactical_rules(d, [SL.RList("when" => ["A > 105", "B > 100"], "weights" => SL.named("A" => 1))], SL.named("C" => 1); env = @__MODULE__))["regime"])", inp = ein("tactical/tr_rx_08", c("d")))))
ref_init("tactical", gruppe = "fehler")
TB("signal_state", "Meldungen von signal_state bei Text statt logischer Werte je Zeile (seit 1.6.3 in Python und Julia wie R: Text in sell scheitert an !, Text in buy an &)", vor = VOR, zeilen = list(
  zeile("ss_err_num2",   # seit 1.6.4 Fehler (Entscheidung 1: nur 0/1; bis 1.6.3 Teil ss_num von text_logik)
    r"(signal_state(list(buy = c(1, 0, NA, 2), sell = c(0, 1, 0, NaN))))",
    r"(result = T.signal_state({'buy': [1.0, 0.0, simlev._r.fmt.NA_REAL, 2.0], 'sell': [0.0, 1.0, 0.0, math.nan]}))",
    r"(result = T.signal_state(SL.RList("buy" => [1.0, 0.0, SL.NA, 2.0], "sell" => [0.0, 1.0, 0.0, NaN])))", inp = list()),
  zeile("ss_err_buy_text",
    r"(signal_state(list(buy = c("TRUE", "FALSE", NA, "TRUE"), sell = c(FALSE, TRUE, FALSE, NA))))",
    r"(result = T.signal_state({'buy': ['TRUE', 'FALSE', None, 'TRUE'], 'sell': [False, True, False, None]}))",
    r"(result = T.signal_state(SL.RList("buy" => ["TRUE", "FALSE", missing, "TRUE"], "sell" => [false, true, false, missing])))", inp = list()),
  zeile("ss_err_sell_text",
    r"(signal_state(list(buy = c(TRUE, FALSE), sell = c("FALSE", "TRUE"))))",
    r"(result = T.signal_state({'buy': [True, False], 'sell': np.array(['FALSE', 'TRUE'])}))",
    r"(result = T.signal_state(SL.RList("buy" => [true, false], "sell" => ["FALSE", "TRUE"])))", inp = list()),
  zeile("ss_err_buy_na_text",
    r"(signal_state(list(buy = NA_character_, sell = FALSE)))",
    r"(result = T.signal_state({'buy': pd.array([None], dtype='string'), 'sell': [False]}))",
    r"(result = T.signal_state(SL.RList("buy" => Union{Missing,String}[missing], "sell" => [false])))", inp = list())))
TB("momentum_score", "Meldungen und Warnungen von momentum_score je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ms_err_miss",
    r"(momentum_score(d, c('A', 'X', 'Y')))",
    r"(result = T.momentum_score(d, ['A', 'X', 'Y']))",
    r"(result = T.momentum_score(d, ["A", "X", "Y"]))", inp = ein("tactical/ms_err_miss", c("d")))))
TB("tactical_rules", "Meldungen und Warnungen von tactical_rules je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("tr_err_signal_text",
    r"(attr(tactical_rules(d, list(list(when = list(buy = rep(c("TRUE", "FALSE"), length.out = nrow(d)), sell = rep(c("FALSE", "TRUE"), length.out = nrow(d))), weights = c(A = 1))), default = c(C = 1)), 'regime'))",
    r"(result = T.tactical_rules(d, [{'when': {'buy': np.resize(['TRUE', 'FALSE'], len(d)), 'sell': np.resize(['FALSE', 'TRUE'], len(d))}, 'weights': {'A': 1}}], default={'C': 1}).attrs['regime'])",
    r"(result = SL.attrs(T.tactical_rules(d, [SL.RList("when" => SL.RList("buy" => repeat(["TRUE", "FALSE"], outer = cld(SL.nrow(d), 2))[1:SL.nrow(d)], "sell" => repeat(["FALSE", "TRUE"], outer = cld(SL.nrow(d), 2))[1:SL.nrow(d)]), "weights" => SL.named("A" => 1))], SL.named("C" => 1); env = @__MODULE__))["regime"])", inp = ein("tactical/tr_rx_08", c("d"))),
  zeile("tr_err_textvec_na",
    r"(attr(tactical_rules(d, list(list(when = c("TRUE", NA, "FALSE", "TRUE"), weights = c(A = 1))), default = c(C = 1)), 'regime'))",
    r"(result = T.tactical_rules(d, [{'when': np.array(['TRUE', None, 'FALSE', 'TRUE'], dtype=object), 'weights': {'A': 1}}], default={'C': 1}).attrs['regime'])",
    r"(result = SL.attrs(T.tactical_rules(d, [SL.RList("when" => ["TRUE", missing, "FALSE", "TRUE"], "weights" => SL.named("A" => 1))], SL.named("C" => 1); env = @__MODULE__))["regime"])", inp = ein("tactical/tr_rx_08", c("d"))),
  zeile("tr_rx_16",
    r"(attr(tactical_rules(d, list(list(when = "\"TRUE\"", weights = c(A = 1)), list(when = 'B > 100', weights = c(B = 1))), default = c(C = 1)), 'regime'))",
    r"(result = T.tactical_rules(d, [{'when': "\"TRUE\"", 'weights': {'A': 1}}, {'when': 'B > 100', 'weights': {'B': 1}}], default={'C': 1}).attrs['regime'])",
    r"(result = SL.attrs(T.tactical_rules(d, [SL.RList("when" => "\"TRUE\"", "weights" => SL.named("A" => 1)), SL.RList("when" => "B > 100", "weights" => SL.named("B" => 1))], SL.named("C" => 1); env = @__MODULE__))["regime"])", inp = ein("tactical/tr_rx_16", c("d"))),
  zeile("tr_rx_25",
    r"(attr(tactical_rules(d, list(list(when = "A[-1] > A[-length(A)]", weights = c(A = 1)), list(when = 'B > 100', weights = c(B = 1))), default = c(C = 1)), 'regime'))",
    r"(result = T.tactical_rules(d, [{'when': "A[-1] > A[-length(A)]", 'weights': {'A': 1}}, {'when': 'B > 100', 'weights': {'B': 1}}], default={'C': 1}).attrs['regime'])",
    r"(result = SL.attrs(T.tactical_rules(d, [SL.RList("when" => "A[-1] > A[-length(A)]", "weights" => SL.named("A" => 1)), SL.RList("when" => "B > 100", "weights" => SL.named("B" => 1))], SL.named("C" => 1); env = @__MODULE__))["regime"])", inp = ein("tactical/tr_rx_25", c("d")))))
TB("tactical_rotation", "Meldungen und Warnungen von tactical_rotation je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("rot_err_safe",
    r"(tactical_rotation(d, c('A', 'B')))",
    r"(result = T.tactical_rotation(d, ['A', 'B']))",
    r"(result = T.tactical_rotation(d, ["A", "B"]))", inp = ein("tactical/rot_err_safe", c("d"))),
  zeile("rot_err_top",
    r"(tactical_rotation(d, c('A', 'B'), safe = 'CASH', top = 3))",
    r"(result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', top=3))",
    r"(result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", top = 3))", inp = ein("tactical/rot_err_top", c("d"))),
  zeile("rot_err_breadth",
    r"(tactical_rotation(d, c('A', 'B'), safe = 'CASH', canary = 'A', breadth = 0))",
    r"(result = T.tactical_rotation(d, ['A', 'B'], safe='CASH', canary='A', breadth=0))",
    r"(result = T.tactical_rotation(d, ["A", "B"]; safe = "CASH", canary = "A", breadth = 0))", inp = ein("tactical/rot_err_breadth", c("d"))),
  zeile("rot_err_short",
    r"(tactical_rotation(d[1:300, ], c('A', 'B'), safe = 'CASH'))",
    r"(result = T.tactical_rotation(d.iloc[:300], ['A', 'B'], safe='CASH'))",
    r"(result = T.tactical_rotation(SL.rows(d, 1:300), ["A", "B"]; safe = "CASH"))", inp = ein("tactical/rot_err_short", c("d")))))
TB("tactical_target_volatility", "Meldungen und Warnungen von tactical_target_volatility je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("tv_warn",
    r"(tactical_target_volatility(d, c(A = 1), safe = 'CASH', target = 0.1))",
    r"(result = T.tactical_target_volatility(d, {'A': 1}, safe='CASH', target=0.1))",
    r"(result = T.tactical_target_volatility(d, SL.named("A" => 1), "CASH"; target = 0.1))", print = TRUE, inp = ein("tactical/tv_warn", c("d"))),
  zeile("tv_err_kredit",
    r"(tactical_target_volatility(d, c(A = 1), safe = 'CASH', max_exposure = 2))",
    r"(result = T.tactical_target_volatility(d, {'A': 1}, safe='CASH', max_exposure=2))",
    r"(result = T.tactical_target_volatility(d, SL.named("A" => 1), "CASH"; max_exposure = 2))", inp = ein("tactical/tv_err_kredit", c("d"))),
  zeile("tv_err_miss",
    r"(tactical_target_volatility(d, c(A = 1, gold = 0.5, x = 1), safe = 'CASH'))",
    r"(result = T.tactical_target_volatility(d, {'A': 1, 'gold': 0.5, 'x': 1}, safe='CASH'))",
    r"(result = T.tactical_target_volatility(d, SL.named("A" => 1, "gold" => 0.5, "x" => 1), "CASH"))", inp = ein("tactical/tv_err_miss", c("d"))),
  zeile("tv_err_safe",
    r"(tactical_target_volatility(d, c(A = 1), safe = 'geld'))",
    r"(result = T.tactical_target_volatility(d, {'A': 1}, safe='geld'))",
    r"(result = T.tactical_target_volatility(d, SL.named("A" => 1), "geld"))", inp = ein("tactical/tv_err_safe", c("d"))),
  zeile("tv_err_unnamed",
    r"(tactical_target_volatility(d, c(1, 2), safe = 'CASH'))",
    r"(result = T.tactical_target_volatility(d, [1, 2], safe='CASH'))",
    r"(result = T.tactical_target_volatility(d, [1, 2], "CASH"))", inp = ein("tactical/tv_err_unnamed", c("d"))),
  zeile("tv_err_mismatch",
    r"(tactical_target_volatility(d, tactical_rules(d[1:100, ], list(), default = c(A = 1)), safe = 'CASH'))",
    r"(result = T.tactical_target_volatility(d, T.tactical_rules(d.iloc[:100], [], default={'A': 1}), safe='CASH'))",
    r"(result = T.tactical_target_volatility(d, T.tactical_rules(SL.rows(d, 1:100), [], SL.named("A" => 1)), "CASH"))", inp = ein("tactical/tv_err_mismatch", c("d"))),
  zeile("tv_err_short",
    r"(tactical_target_volatility(d[1:50, ], c(A = 1), safe = 'CASH'))",
    r"(result = T.tactical_target_volatility(d.iloc[:50], {'A': 1}, safe='CASH'))",
    r"(result = T.tactical_target_volatility(SL.rows(d, 1:50), SL.named("A" => 1), "CASH"))", inp = ein("tactical/tv_err_short", c("d")))))
TB("tactical_conditional_volatility", "Meldungen und Warnungen von tactical_conditional_volatility je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("cv_target_warn",
    r"(tactical_conditional_volatility(d, c(B = 1), safe = 'C', base = 0.5, min_history = 1.5, target = 0.12, min_exposure = 0.2, max_exposure = 0.9, every = 'quarter'))",
    r"(result = T.tactical_conditional_volatility(d, {'B': 1}, safe='C', base=0.5, min_history=1.5, target=0.12, min_exposure=0.2, max_exposure=0.9, every='quarter'))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("B" => 1), "C"; base = 0.5, min_history = 1.5, target = 0.12, min_exposure = 0.2, max_exposure = 0.9, every = "quarter"))", print = TRUE, inp = ein("tactical/cv_target_warn", c("d"))),
  zeile("cv_err_kredit",
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', max_exposure = 1.5))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', max_exposure=1.5))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; max_exposure = 1.5))", inp = ein("tactical/cv_err_kredit", c("d"))),
  zeile("cv_err_base",
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 1.2, max_exposure = 1))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=1.2))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 1.2, max_exposure = 1))", inp = ein("tactical/cv_err_base", c("d"))),
  zeile("cv_err_min",
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, min_exposure = 0.6))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, min_exposure=0.6))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, min_exposure = 0.6))", inp = ein("tactical/cv_err_min", c("d"))),
  zeile("cv_err_upper",
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', upper = 1))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', upper=1))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; upper = 1))", inp = ein("tactical/cv_err_upper", c("d"))),
  zeile("cv_err_lower",
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', lower = 0.9))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', lower=0.9))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; lower = 0.9))", inp = ein("tactical/cv_err_lower", c("d"))),
  zeile("cv_err_fixed",
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', scaling = 'fixed', high_exposure = 0.3))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', scaling='fixed', high_exposure=0.3))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; scaling = "fixed", high_exposure = 0.3))", inp = ein("tactical/cv_err_fixed", c("d"))),
  zeile("cv_err_high",
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, scaling = 'fixed', high_exposure = 0.6, lower = NULL))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, scaling='fixed', high_exposure=0.6, lower=None))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, scaling = "fixed", high_exposure = 0.6, lower = nothing))", inp = ein("tactical/cv_err_high", c("d"))),
  zeile("cv_err_low",
    r"(tactical_conditional_volatility(d, c(A = 1), safe = 'CASH', base = 0.5, scaling = 'fixed', high_exposure = 0.3, low_exposure = 0.4))",
    r"(result = T.tactical_conditional_volatility(d, {'A': 1}, safe='CASH', base=0.5, scaling='fixed', high_exposure=0.3, low_exposure=0.4))",
    r"(result = T.tactical_conditional_volatility(d, SL.named("A" => 1), "CASH"; base = 0.5, scaling = "fixed", high_exposure = 0.3, low_exposure = 0.4))", inp = ein("tactical/cv_err_low", c("d"))),
  zeile("cv_err_short",
    r"(tactical_conditional_volatility(d[1:40, ], c(A = 1), safe = 'CASH', base = 0.8))",
    r"(result = T.tactical_conditional_volatility(d.iloc[:40], {'A': 1}, safe='CASH', base=0.8))",
    r"(result = T.tactical_conditional_volatility(SL.rows(d, 1:40), SL.named("A" => 1), "CASH"; base = 0.8))", inp = ein("tactical/cv_err_short", c("d")))))
TB("tactical_glidepath", "Meldungen und Warnungen von tactical_glidepath je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("gp_err",
    r"(tactical_glidepath(d, from = c(A = 0.9, C = 0.1), to = c(A = 0.4, C = 0.6), start = '2014-01-01', end = '2013-01-01'))",
    r"(result = T.tactical_glidepath(d, from_={'A': 0.9, 'C': 0.1}, to={'A': 0.4, 'C': 0.6}, start='2014-01-01', end='2013-01-01'))",
    r"(result = T.tactical_glidepath(d, SL.named("A" => 0.9, "C" => 0.1), SL.named("A" => 0.4, "C" => 0.6); start = "2014-01-01", end_ = "2013-01-01"))", inp = ein("tactical/gp_err", c("d")))))
TB("tactical_blend", "Meldungen und Warnungen von tactical_blend je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("bl_err_shares",
    r"(tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d, list(), default = c(B = 1)), shares = 0.7))",
    r"(result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d, [], default={'B': 1}), shares=0.7))",
    r"(result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(d, [], SL.named("B" => 1)); shares = 0.7))", inp = ein("tactical/bl_err_shares", c("d"))),
  zeile("bl_err_empty",
    r"(tactical_blend())",
    r"(result = T.tactical_blend())",
    r"(result = T.tactical_blend())", inp = ein("tactical/bl_err_empty", c())),
  zeile("bl_err_dates",
    r"(tactical_blend(tactical_rules(d, list(), default = c(A = 1)), tactical_rules(d[1:10, ], list(), default = c(B = 1))))",
    r"(result = T.tactical_blend(T.tactical_rules(d, [], default={'A': 1}), T.tactical_rules(d.iloc[:10], [], default={'B': 1})))",
    r"(result = T.tactical_blend(T.tactical_rules(d, [], SL.named("A" => 1)), T.tactical_rules(SL.rows(d, 1:10), [], SL.named("B" => 1))))", inp = ein("tactical/bl_err_dates", c("d")))))
TB(".period_last", "Meldungen und Warnungen von .period_last je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("helpers_err",
    r"(SimLev:::.period_last(d$date, 'decade'))",
    r"(result = T._period_last(d['date'], 'decade'))",
    r"(result = T._period_last(d.date, "decade"))", inp = ein("tactical/helpers_err", c("d")))))
TB(".as_weights", "Meldungen und Warnungen von .as_weights je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("as_weights_err",
    r"(SimLev:::.as_weights(d$date[1:3], matrix(c(1, 0, NA, 0, -1, 0), 3)))",
    r"(result = T._as_weights(d['date'][:3], np.array([[1, 0], [0, -1], [simlev._r.fmt.NA_REAL, 0]])))",
    r"(result = T._as_weights(d.date[1:3], [1 0; 0 -1; SL.NA 0]))", inp = ein("tactical/as_weights_err", c("d")))))
TB("tactical_simulation", "Meldungen und Warnungen von tactical_simulation je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ts_err_w",
    r"(tactical_simulation(ds, c(A = 1)))",
    r"(result = T.tactical_simulation(ds, {'A': 1}))",
    r"(result = T.tactical_simulation(ds, SL.named("A" => 1)))", inp = ein("tactical/ts_err_w", c("ds"))),
  zeile("ts_err_args",
    r"(tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), balance_mode = TRUE, event_col = 'x'))",
    r"(result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), balance_mode=True, event_col='x'))",
    r"(result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); balance_mode = true, event_col = "x"))", inp = ein("tactical/ts_err_args", c("ds"))),
  zeile("ts_err_cols",
    r"(tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1, X = 1, Y = 1))))",
    r"(result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1, 'X': 1, 'Y': 1})))",
    r"(result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1, "X" => 1, "Y" => 1))))", inp = ein("tactical/ts_err_cols", c("ds"))),
  zeile("ts_err_lag2",
    r"(tactical_simulation(ds, tactical_rules(ds, list(), default = c(A = 1)), lag = 'x'))",
    r"(result = T.tactical_simulation(ds, T.tactical_rules(ds, [], default={'A': 1}), lag='x'))",
    r"(result = T.tactical_simulation(ds, T.tactical_rules(ds, [], SL.named("A" => 1)); lag = "x"))", inp = ein("tactical/ts_err_lag2", c("ds")))))
ref_done()

ref_schreiben()
