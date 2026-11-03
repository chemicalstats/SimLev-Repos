# tests/gleichlauf/erzeugen/optimierung.R – Bereich optimierung als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 Einzelfälle je Modul und Funktion).
# Portfolio-Optimierung: Verfahren (Varianz, Diversifikation, CVaR, CDaR, Risikoparität, HRP), Kovarianzschätzer,
# Effizienzlinie, Risikobeiträge, rollierende Optimierung, CPCV, Eingabeprüfungen.
#   gleichlauf  Szenarien: je Szenario ein Aufruf bzw. eine kurze Aufrufkette, die mehrere Ergebnisse zugleich prüft
#               (Teile; Name = bisherige Fallkennung). Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     print()/summary() als Tabelle
# Herkunft der Erwartung: R. Daten und Hilfen wie in tests/werkzeuge/breite/optimierung.R (Breitenprüfung mit allen bisherigen Fällen).
# Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/optimierung.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/optimierung.jsonl.gz (Format: ref_tools.R, Szenarien: szenario_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R"); source("tests/gleichlauf/erzeugen/szenario_tools.R")
ref_bereich("optimierung")
EIN <- list()   # Eingaben je bisherigem Fall (Momentaufnahme an der Stelle, an der der Fall im alten Generator stand)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# Modul optimize
# ════════════════════════════════════════════════════════════════════════════════════════════════════
P <- "from simlev import optimize as O\nfrom simlev import _optimize_core as C\n"
J <- "O = SL.Optimize; C = SL.OptimizeCore\n"   # Kopf des Julia-Codes (jl)
# ── Daten ────────────────────────────────────────────────────────────────────
set.seed(1)
R <- matrix(rnorm(260 * 3, c(0.002, 0.001, 0.0005), c(0.03, 0.02, 0.01)), 260, byrow = TRUE)
colnames(R) <- c("aktien", "reits", "anleihen")
set.seed(3)
S0 <- matrix(c(0.04, 0.012, 0.006, 0.002, 0.012, 0.0225, 0.004, 0.001, 0.006, 0.004, 0.01, 0.0005,
               0.002, 0.001, 0.0005, 0.0025), 4) / 52
R4 <- matrix(rnorm(156 * 4), 156) %*% chol(S0) + matrix(c(0.08, 0.06, 0.04, 0.02) / 52, 156, 4, byrow = TRUE)
colnames(R4) <- c("A", "B", "C", "D")
Rc <- cbind(R, cash = 0.0005)
R1 <- R[, 1, drop = FALSE]
Rna <- R; Rna[c(5, 77), 2] <- NA
Rinf <- R; Rinf[c(9, 12), 2] <- Inf; Rinf[4, 3] <- -Inf
Rnn <- unname(R[1:120, ])
set.seed(2); n <- 548   # bis 1.4.1 n <- 3 * 365 (kürzer, Abdeckung gleich)
d <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n))
d$aktien <- 100 * cumprod(1 + rnorm(n, 3e-4, 0.01))
d$anleihen <- 100 * cumprod(1 + rnorm(n, 1e-4, 0.003))
d$gold <- 100 * cumprod(1 + rnorm(n, 2e-4, 0.008))
dna <- d; dna$aktien[100:106] <- NA
d0 <- d; d0$aktien[100:106] <- 0
dsh <- d[c(500:1, 501:n), ]
ddup <- rbind(d, d[5, ])
I <- list(R = R, R4 = R4, Rc = Rc, R1 = R1, Rna = Rna, Rinf = Rinf, Rnn = Rnn, d = d)
# ── Kerne ────────────────────────────────────────────────────────────────────
set.seed(11)
pv <- list(); plo <- list(); phi <- list()
for (k in 1:25) {
  m <- sample(2:12, 1); v <- rnorm(m, 0, 2); lo <- runif(m, 0, 0.05); hi <- pmax(lo + 0.05, runif(m, 0.1, 0.8))
  if (sum(hi) < 1) hi <- hi / sum(hi) * 1.2
  pv[[k]] <- v; plo[[k]] <- lo; phi[[k]] <- hi
}
pv[[26]] <- c(0.2, 0.2, 0.2); plo[[26]] <- c(0, 0, 0); phi[[26]] <- c(0.3, 0.3, 0.3)   # sum(hi) <= 1
pv[[27]] <- c(0.2, 0.2); plo[[27]] <- c(0.6, 0.5); phi[[27]] <- c(1, 1)               # sum(lo) >= 1
pv[[28]] <- c(0, 0, 0, 0); plo[[28]] <- c(0, 0, 0, 0); phi[[28]] <- c(1, 1, 1, 1)     # Gleichstaende
pv[[29]] <- c(-0, 0, 1, -0, 0.5, 0, 0, -0, 0, 0); plo[[29]] <- rep(0, 10); phi[[29]] <- c(rep(0.5, 9), 0)  # +0/-0
Ip <- list(pv = pv, plo = plo, phi = phi)
set.seed(2); A <- matrix(rnorm(400), 100); Sq <- crossprod(A) / 100
Iq <- list(Sq = Sq, cq = c(-0.1, 0.05, 0, 0.2), lq = c(0, 0.1, 0, 0), hq = c(1, 0.5, 0.3, 1))
Ic <- list(Rs = R[1:120, ])
for (ct in c("sample", "ledoit_wolf", "ewma", "denoise", "gerber")) EIN[[paste0("optimize/", paste0("cov_", ct))]] <- I
# ── portfolio_optimize: Verfahren ────────────────────────────────────────────
meths <- c("min_variance", "max_sharpe", "mean_variance", "max_diversification", "risk_parity", "hrp",
           "min_cvar", "min_cdar", "inverse_vol", "equal")
for (m in meths) {
    EIN[[paste0("optimize/", paste0("po_", m))]] <- I
    EIN[[paste0("optimize/", paste0("po4_", m))]] <- I
}
for (ct in c("ledoit_wolf", "ewma", "denoise", "gerber")) {
    EIN[[paste0("optimize/", paste0("po_cov_", ct))]] <- I
    EIN[[paste0("optimize/", paste0("po_cov_rp_", ct))]] <- I
    EIN[[paste0("optimize/", paste0("po_cov_ms_", ct))]] <- I
}
for (m in c("equal", "inverse_vol", "risk_parity", "hrp")) EIN[[paste0("optimize/", paste0("po_ignored_", m))]] <- I
for (fq in c("day", "month")) EIN[[paste0("optimize/", paste0("po_freq_", fq))]] <- I
for (m in c("risk_parity", "hrp", "inverse_vol")) EIN[[paste0("optimize/", paste0("po_flat_err_", m))]] <- I
EIN[["optimize/po_df_dup"]] <- list(ddup = ddup)
for (ct in c("ledoit_wolf", "ewma", "denoise", "gerber")) EIN[[paste0("optimize/", paste0("ef_cov_", ct))]] <- I
for (ct in c("ewma", "denoise", "gerber")) EIN[[paste0("optimize/", paste0("rc_cov_", ct))]] <- I
# ── portfolio_rolling ─────────────────────────────────────────────────────
set.seed(1); n2 <- 4 * 365
d2 <- data.frame(date = seq.Date(as.Date("2015-01-01"), by = "day", length.out = n2))
d2$a <- 100 * cumprod(1 + rnorm(n2, 3e-4, 0.01)); d2$b <- 100 * cumprod(1 + rnorm(n2, 1e-4, 0.003))
d2$c <- 100 * cumprod(1 + rnorm(n2, 2e-4, 0.007))
d2s <- d2[c(n2:1001, 1:1000), ]
I2 <- list(d2 = d2)

# Vorspann je Szenario bzw. Tabellenzeile (gemeinsame Objekte des Moduls)
VOR <- list(r = r"()",
            py = r"(from simlev import optimize as O
from simlev import _optimize_core as C)",
            jl = r"(O = SL.Optimize; C = SL.OptimizeCore)")

ref_init("optimize", gruppe = "gleichlauf")
SZ("kerne_und_hilfen", ".min_cvar_core, .opt_cov gerber bei flachen Reihen, .cvar_hist und .cdar_hist", vor = VOR, teile = list(
  core_cvar = teil(
    r"(list(SimLev:::.min_cvar_core(Rs, 0.05, rep(0, 3), rep(1, 3), rep(1/3, 3), 0.02, c(0.002, 0.0002), 2000L),
                      SimLev:::.min_cvar_core(Rs, 0.2, c(0.1, 0, 0), c(0.5, 1, 0.6), c(0.4, 0.3, 0.3), 0.01, 0.001, 50L)))",
    r"(result = [C.min_cvar_core(Rs, 0.05, [0.0] * 3, [1.0] * 3, [1/3] * 3, 0.02, [0.002, 0.0002], 2000),
          C.min_cvar_core(Rs, 0.2, [0.1, 0, 0], [0.5, 1, 0.6], [0.4, 0.3, 0.3], 0.01, [0.001], 50)])",
    r"(result = [C.min_cvar_core(Rs, 0.05, zeros(3), ones(3), fill(1 / 3, 3), 0.02, [0.002, 0.0002], 2000),
          C.min_cvar_core(Rs, 0.2, [0.1, 0, 0], [0.5, 1, 0.6], [0.4, 0.3, 0.3], 0.01, 0.001, 50)])", inp = ein("optimize/core_cvar", c("Rs"))),
  cov_gerber_flat = teil(
    r"(SimLev:::.opt_cov(Rc, 'gerber'))",
    r"(result = O._opt_cov(Rc, 'gerber'))",
    r"(result = O._opt_cov(Rc, "gerber"))", inp = ein("optimize/cov_gerber_flat", c("Rc"))),
  helpers_hist = teil(
    r"(list(SimLev:::.cvar_hist(R %*% c(0.5, 0.2, 0.3), 0.05), SimLev:::.cdar_hist(drop(R %*% c(0.5, 0.2, 0.3)), 0.1),
                        SimLev:::.hrp(cov(R4)), SimLev:::.risk_parity(cov(R4), c(0.4, 0.3, 0.2, 0.1)),
                        SimLev:::.qp_simplex(cov(R4) * 52, -colMeans(R4) * 52, rep(0, 4), rep(1, 4))))",
    r"(import numpy as np
rs = np.asarray(R) @ np.array([0.5, 0.2, 0.3])
result = [O._cvar_hist(O._mat_vec(R, [0.5, 0.2, 0.3]), 0.05), O._cdar_hist(O._mat_vec(R, [0.5, 0.2, 0.3]), 0.1),
          O._hrp(O._cov(R4)), O._risk_parity(O._cov(R4), [0.4, 0.3, 0.2, 0.1]),
          O._qp_simplex(O._cov(R4) * 52, -O._col_means(R4) * 52, [0.0] * 4, [1.0] * 4)])",
    r"(w = [0.5, 0.2, 0.3]
result = [O._cvar_hist(O._mat_vec(R, w), 0.05), O._cdar_hist(O._mat_vec(R, w), 0.1),
          O._hrp(O._cov(R4)), O._risk_parity(O._cov(R4), [0.4, 0.3, 0.2, 0.1]),
          O._qp_simplex(O._cov(R4) .* 52, .-O._col_means(R4) .* 52, zeros(4), ones(4))])", inp = ein("optimize/helpers_hist", c("R", "R4")))))
SZ("verfahren_vier_anlagen", "portfolio_optimize auf vier Anlagen: min_variance (Grafikdaten), mean_variance, max_diversification, min_cdar, Risikoparität mit Teilbudget", vor = VOR, teile = list(
  po4_min_variance = teil(
    r"(portfolio_optimize(R4, method = 'min_variance'))",
    r"(result = O.portfolio_optimize(R4, method='min_variance'))",
    r"(result = O.portfolio_optimize(R4; method = "min_variance"))", druck = TRUE, inp = ein("optimize/po4_min_variance", c("R4"))),
  po4_mean_variance = teil(
    r"(portfolio_optimize(R4, method = 'mean_variance'))",
    r"(result = O.portfolio_optimize(R4, method='mean_variance'))",
    r"(result = O.portfolio_optimize(R4; method = "mean_variance"))", druck = TRUE, inp = ein("optimize/po4_mean_variance", c("R4"))),
  po4_max_diversification = teil(
    r"(portfolio_optimize(R4, method = 'max_diversification'))",
    r"(result = O.portfolio_optimize(R4, method='max_diversification'))",
    r"(result = O.portfolio_optimize(R4; method = "max_diversification"))", druck = TRUE, inp = ein("optimize/po4_max_diversification", c("R4"))),
  po4_min_cdar = teil(
    r"(portfolio_optimize(R4, method = 'min_cdar'))",
    r"(result = O.portfolio_optimize(R4, method='min_cdar'))",
    r"(result = O.portfolio_optimize(R4; method = "min_cdar"))", druck = TRUE, inp = ein("optimize/po4_min_cdar", c("R4"))),
  po_budget_part = teil(
    r"(portfolio_optimize(R4, method = 'risk_parity', budget = c(A = 1, C = 2)))",
    r"(import pandas as pd
result = O.portfolio_optimize(R4, method='risk_parity', budget=pd.Series({'A': 1, 'C': 2})))",
    r"(result = O.portfolio_optimize(R4; method = "risk_parity", budget = SL.named("A" => 1, "C" => 2)))", druck = TRUE, inp = ein("optimize/po_budget_part", c("R4")))))
SZ("sonderfaelle_optimierung", "Risikoparität mit Resampling, eine Anlage (hrp), Tabelle mit Tagesrenditen (min_cvar)", vor = VOR, teile = list(
  po_resample_null = teil(
    r"(simlev_seed(3); x <- portfolio_optimize(R, method = 'risk_parity', resample = 4); list(x, SimLev:::.sl_runif(2)))",
    r"(simlev.simlev_seed(3); x = O.portfolio_optimize(R, method='risk_parity', resample=4); result = [x, simlev._lib.runif(2)])",
    r"(SL.simlev_seed(3); x = O.portfolio_optimize(R; method = "risk_parity", resample = 4); result = [x, SL.SLib.runif(2)])", inp = ein("optimize/po_resample_null", c("R"))),
  po_n1 = teil(
    r"(portfolio_optimize(R1, method = 'hrp'))",
    r"(result = O.portfolio_optimize(R1, method='hrp'))",
    r"(result = O.portfolio_optimize(R1; method = "hrp"))", druck = TRUE, inp = ein("optimize/po_n1", c("R1"))),
  po_df_day = teil(
    r"(portfolio_optimize(d, assets = c('gold', 'aktien'), method = 'min_cvar', frequency = 'day'))",
    r"(result = O.portfolio_optimize(d, assets=['gold', 'aktien'], method='min_cvar', frequency='day'))",
    r"(result = O.portfolio_optimize(d; assets = ["gold", "aktien"], method = "min_cvar", frequency = "day"))", druck = TRUE, inp = ein("optimize/po_df_day", c("d")))))
SZ("effizienzlinie_und_risikobeitraege", "portfolio_frontier; portfolio_risk_contributions mit CVaR, mit Optimierungsergebnis (Ledoit-Wolf), EWMA und Matrix ohne Namen", vor = VOR, teile = list(
  ef_default = teil(
    r"(portfolio_frontier(R))",
    r"(result = O.portfolio_frontier(R))",
    r"(result = O.portfolio_frontier(R))", druck = TRUE, inp = ein("optimize/ef_default", c("R"))),
  rc_cvar_a = teil(
    r"(portfolio_risk_contributions(R4, c(D = 0.4, A = 0.6), measure = 'cvar', alpha = 0.2))",
    r"(import pandas as pd
result = O.portfolio_risk_contributions(R4, pd.Series({'D': 0.4, 'A': 0.6}), measure='cvar', alpha=0.2))",
    r"(result = O.portfolio_risk_contributions(R4, SL.named("D" => 0.4, "A" => 0.6); measure = "cvar", alpha = 0.2))", inp = ein("optimize/rc_cvar_a", c("R4"))),
  rc_opt = teil(
    r"(portfolio_risk_contributions(R4, portfolio_optimize(R4, method = 'hrp'), cov = 'ledoit_wolf'))",
    r"(result = O.portfolio_risk_contributions(R4, O.portfolio_optimize(R4, method='hrp'), cov='ledoit_wolf'))",
    r"(result = O.portfolio_risk_contributions(R4, O.portfolio_optimize(R4; method = "hrp"); cov = "ledoit_wolf"))", inp = ein("optimize/rc_opt", c("R4"))),
  rc_cov_ewma = teil(
    r"(portfolio_risk_contributions(R4, c(A = 0.25, B = 0.25, C = 0.25, D = 0.25), cov = 'ewma', frequency = 'month'))",
    r"(import pandas as pd
result = O.portfolio_risk_contributions(R4, pd.Series({'A': 0.25, 'B': 0.25, 'C': 0.25, 'D': 0.25}), cov='ewma', frequency='month'))",
    r"(result = O.portfolio_risk_contributions(R4, SL.named("A" => 0.25, "B" => 0.25, "C" => 0.25, "D" => 0.25); cov = "ewma", frequency = "month"))", inp = ein("optimize/rc_cov_ewma", c("R4"))),
  rc_noname_mat = teil(
    r"(portfolio_risk_contributions(Rnn, c(A2 = 0.5, A3 = 0.5)))",
    r"(import pandas as pd
result = O.portfolio_risk_contributions(Rnn, pd.Series({'A2': 0.5, 'A3': 0.5})))",
    r"(result = O.portfolio_risk_contributions(Rnn, SL.named("A2" => 0.5, "A3" => 0.5)))", inp = ein("optimize/rc_noname_mat", c("Rnn")))))
SZ("rollierend_und_cpcv", "portfolio_rolling (max_sharpe, Quartale, Obergrenzen), portfolio_cpcv mit drei Verfahren und mit Tagesdaten", vor = VOR, teile = list(
  ro_bounds = teil(
    r"(portfolio_rolling(d2, c('a', 'b', 'c'), 'max_sharpe', window = 2, every = 'quarter', upper = c(b = 0.5), mu = c(a = 6, b = 2, c = 4)))",
    r"(import pandas as pd
result = O.portfolio_rolling(d2, ['a', 'b', 'c'], method='max_sharpe', window=2, every='quarter', upper=pd.Series({'b': 0.5}), mu=pd.Series({'a': 6, 'b': 2, 'c': 4})))",
    r"(result = O.portfolio_rolling(d2, ["a", "b", "c"]; method = "max_sharpe", window = 2, every = "quarter", upper = SL.named("b" => 0.5), mu = SL.named("a" => 6, "b" => 2, "c" => 4)))", druck = TRUE, inp = ein("optimize/ro_bounds", c("d2"))),
  cp_basic = teil(
    r"(portfolio_cpcv(R, methods = c('equal', 'inverse_vol', 'min_variance'), n_groups = 5, test_groups = 2))",
    r"(result = O.portfolio_cpcv(R, methods=['equal', 'inverse_vol', 'min_variance'], n_groups=5, test_groups=2))",
    r"(result = O.portfolio_cpcv(R; methods = ["equal", "inverse_vol", "min_variance"], n_groups = 5, test_groups = 2))", druck = TRUE, inp = ein("optimize/cp_basic", c("R"))),
  cp_df_day = teil(
    r"(portfolio_cpcv(d, methods = 'min_variance', frequency = 'day', n_groups = 4, test_groups = 1, purge = 5, embargo = 0))",
    r"(result = O.portfolio_cpcv(d, methods='min_variance', frequency='day', n_groups=4, test_groups=1, purge=5, embargo=0))",
    r"(result = O.portfolio_cpcv(d; methods = "min_variance", frequency = "day", n_groups = 4, test_groups = 1, purge = 5, embargo = 0))", druck = TRUE, inp = ein("optimize/cp_df_day", c("d")))))
ref_done()

ref_init("optimize", gruppe = "fehler")
TB("portfolio_optimize", "Meldungen und Warnungen von portfolio_optimize je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("po_ignored_equal",
    r"(portfolio_optimize(R, method = 'equal', upper = 0.5))",
    r"(result = O.portfolio_optimize(R, method='equal', upper=0.5))",
    r"(result = O.portfolio_optimize(R; method = "equal", upper = 0.5))", print = TRUE, inp = ein("optimize/po_ignored_equal", c("R"))),
  zeile("po_ignored_inverse_vol",
    r"(portfolio_optimize(R, method = 'inverse_vol', upper = 0.5))",
    r"(result = O.portfolio_optimize(R, method='inverse_vol', upper=0.5))",
    r"(result = O.portfolio_optimize(R; method = "inverse_vol", upper = 0.5))", print = TRUE, inp = ein("optimize/po_ignored_inverse_vol", c("R"))),
  zeile("po_ignored_risk_parity",
    r"(portfolio_optimize(R, method = 'risk_parity', upper = 0.5))",
    r"(result = O.portfolio_optimize(R, method='risk_parity', upper=0.5))",
    r"(result = O.portfolio_optimize(R; method = "risk_parity", upper = 0.5))", print = TRUE, inp = ein("optimize/po_ignored_risk_parity", c("R"))),
  zeile("po_ignored_hrp",
    r"(portfolio_optimize(R, method = 'hrp', upper = 0.5))",
    r"(result = O.portfolio_optimize(R, method='hrp', upper=0.5))",
    r"(result = O.portfolio_optimize(R; method = "hrp", upper = 0.5))", print = TRUE, inp = ein("optimize/po_ignored_hrp", c("R"))),
  zeile("po_flat_denoise",
    r"(portfolio_optimize(Rc, cov = 'denoise'))",
    r"(result = O.portfolio_optimize(Rc, cov='denoise'))",
    r"(result = O.portfolio_optimize(Rc; cov = "denoise"))", print = TRUE, inp = ein("optimize/po_flat_denoise", c("Rc"))),
  zeile("po_flat_err_hrp",
    r"(portfolio_optimize(Rc, method = 'hrp'))",
    r"(result = O.portfolio_optimize(Rc, method='hrp'))",
    r"(result = O.portfolio_optimize(Rc; method = "hrp"))", inp = ein("optimize/po_flat_err_hrp", c("Rc"))),
  zeile("po_df_dup",
    r"(portfolio_optimize(ddup))",
    r"(result = O.portfolio_optimize(ddup))",
    r"(result = O.portfolio_optimize(ddup))", inp = ein("optimize/po_df_dup", c("ddup"))),
  zeile("err_chr",
    r"(portfolio_optimize(R, lower = 'a'))",
    r"(result = O.portfolio_optimize(R, lower='a'))",
    r"(result = O.portfolio_optimize(R; lower = "a"))", inp = ein("optimize/err_chr", c("R"))),
  zeile("err_neg2",
    r"(portfolio_optimize(R, lower = c(-0.5, 0, -0.25)))",
    r"(result = O.portfolio_optimize(R, lower=[-0.5, 0, -0.25]))",
    r"(result = O.portfolio_optimize(R; lower = [-0.5, 0, -0.25]))", inp = ein("optimize/err_neg2", c("R"))),
  zeile("err_alpha5",
    r"(portfolio_optimize(R, method = 'min_cvar', alpha = 5))",
    r"(result = O.portfolio_optimize(R, method='min_cvar', alpha=5))",
    r"(result = O.portfolio_optimize(R; method = "min_cvar", alpha = 5))", inp = ein("optimize/err_alpha5", c("R"))),
  zeile("err_alpha0",
    r"(portfolio_optimize(R, alpha = 0))",
    r"(result = O.portfolio_optimize(R, alpha=0))",
    r"(result = O.portfolio_optimize(R; alpha = 0))", inp = ein("optimize/err_alpha0", c("R"))),
  zeile("err_mu_unknown",
    r"(portfolio_optimize(R4, method = 'max_sharpe', mu = c(A = 5, B = 6, C = 7, X = 8)))",
    r"(import pandas as pd
result = O.portfolio_optimize(R4, method='max_sharpe', mu=pd.Series({'A': 5, 'B': 6, 'C': 7, 'X': 8})))",
    r"(result = O.portfolio_optimize(R4; method = "max_sharpe", mu = SL.named("A" => 5, "B" => 6, "C" => 7, "X" => 8)))", inp = ein("optimize/err_mu_unknown", c("R4"))),
  zeile("err_mu_missing_mv",
    r"(portfolio_optimize(R4, method = 'mean_variance', mu = c(C = 5)))",
    r"(import pandas as pd
result = O.portfolio_optimize(R4, method='mean_variance', mu=pd.Series({'C': 5})))",
    r"(result = O.portfolio_optimize(R4; method = "mean_variance", mu = SL.named("C" => 5)))", inp = ein("optimize/err_mu_missing_mv", c("R4"))),
  zeile("err_mu_len",
    r"(portfolio_optimize(R4, method = 'max_sharpe', mu = c(5, 6)))",
    r"(result = O.portfolio_optimize(R4, method='max_sharpe', mu=[5, 6]))",
    r"(result = O.portfolio_optimize(R4; method = "max_sharpe", mu = [5, 6]))", inp = ein("optimize/err_mu_len", c("R4"))),
  zeile("err_mu_inf",
    r"(portfolio_optimize(R4, method = 'max_sharpe', mu = c(5, 6, Inf, 8)))",
    r"(import math
result = O.portfolio_optimize(R4, method='max_sharpe', mu=[5, 6, math.inf, 8]))",
    r"(result = O.portfolio_optimize(R4; method = "max_sharpe", mu = [5, 6, Inf, 8]))", inp = ein("optimize/err_mu_inf", c("R4"))),
  zeile("err_budget",
    r"(portfolio_optimize(R, method = 'risk_parity', budget = c(1, -1, 0.5)))",
    r"(result = O.portfolio_optimize(R, method='risk_parity', budget=[1, -1, 0.5]))",
    r"(result = O.portfolio_optimize(R; method = "risk_parity", budget = [1, -1, 0.5]))", inp = ein("optimize/err_budget", c("R"))),
  zeile("err_inf",
    r"(portfolio_optimize(Rinf))",
    r"(result = O.portfolio_optimize(Rinf))",
    r"(result = O.portfolio_optimize(Rinf))", inp = ein("optimize/err_inf", c("Rinf"))),
  zeile("err_assets",
    r"(portfolio_optimize(R, assets = c('aktien', 'gold')))",
    r"(result = O.portfolio_optimize(R, assets=['aktien', 'gold']))",
    r"(result = O.portfolio_optimize(R; assets = ["aktien", "gold"]))", inp = ein("optimize/err_assets", c("R"))),
  zeile("err_nonnum",
    r"(portfolio_optimize(matrix(letters[1:20], 10)))",
    r"(import numpy as np
result = O.portfolio_optimize(np.array([[chr(97 + i + 10 * j) for j in range(2)] for i in range(10)], dtype=object)))",
    r"(result = O.portfolio_optimize(reshape([string(c) for c in "abcdefghijklmnopqrst"], 10, 2)))", inp = ein("optimize/err_nonnum", c()))))
TB("portfolio_risk_contributions", "Meldungen und Warnungen von portfolio_risk_contributions je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("rc_err_unknown_df",
    r"(portfolio_risk_contributions(d, c(aktien = 0.5, bar = 0.5)))",
    r"(import pandas as pd
result = O.portfolio_risk_contributions(d, pd.Series({'aktien': 0.5, 'bar': 0.5})))",
    r"(result = O.portfolio_risk_contributions(d, SL.named("aktien" => 0.5, "bar" => 0.5)))", inp = ein("optimize/rc_err_unknown_df", c("d"))),
  zeile("rc_err_alpha",
    r"(portfolio_risk_contributions(R4, c(A = 0.5, B = 0.5), measure = 'cvar', alpha = 0.95))",
    r"(import pandas as pd
result = O.portfolio_risk_contributions(R4, pd.Series({'A': 0.5, 'B': 0.5}), measure='cvar', alpha=0.95))",
    r"(result = O.portfolio_risk_contributions(R4, SL.named("A" => 0.5, "B" => 0.5); measure = "cvar", alpha = 0.95))", inp = ein("optimize/rc_err_alpha", c("R4"))),
  zeile("rc_err_na",
    r"(portfolio_risk_contributions(R4, c(A = 0.5, B = NA)))",
    r"(import pandas as pd, math
result = O.portfolio_risk_contributions(R4, pd.Series({'A': 0.5, 'B': simlev._r.fmt.NA_REAL})))",
    r"(result = O.portfolio_risk_contributions(R4, SL.named("A" => 0.5, "B" => SL.NA)))", inp = ein("optimize/rc_err_na", c("R4")))))
TB("portfolio_rolling", "Meldungen und Warnungen von portfolio_rolling je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("ro_fail",
    r"(w <- portfolio_rolling(d2, c('a', 'b'), window = 0.5, frequency = 'month'); list(w, attr(w, 'failed_dates')))",
    r"(w = O.portfolio_rolling(d2, ['a', 'b'], window=0.5, frequency='month'); result = [w, w.attrs['failed_dates']])",
    r"(w = O.portfolio_rolling(d2, ["a", "b"]; window = 0.5, frequency = "month"); result = [w, SL.attrs(w)["failed_dates"]])", inp = ein("optimize/ro_fail", c("d2"))),
  zeile("ro_err_method",
    r"(portfolio_rolling(d2, c('a', 'b'), method = 'min_varianze', window = 2))",
    r"(result = O.portfolio_rolling(d2, ['a', 'b'], method='min_varianze', window=2))",
    r"(result = O.portfolio_rolling(d2, ["a", "b"]; method = "min_varianze", window = 2))", inp = ein("optimize/ro_err_method", c("d2"))),
  zeile("ro_err_arg",
    r"(portfolio_rolling(d2, c('a', 'b'), window = 2, uper = 0.5))",
    r"(result = O.portfolio_rolling(d2, ['a', 'b'], window=2, uper=0.5))",
    r"(result = O.portfolio_rolling(d2, ["a", "b"]; window = 2, uper = 0.5))", inp = ein("optimize/ro_err_arg", c("d2"))),
  zeile("ro_err_df",
    r"(portfolio_rolling(R, c('aktien'), window = 2))",
    r"(result = O.portfolio_rolling(R, ['aktien'], window=2))",
    r"(result = O.portfolio_rolling(R, ["aktien"]; window = 2))", inp = ein("optimize/ro_err_df", c("R"))),
  zeile("ro_err_cols",
    r"(portfolio_rolling(d2, c('a', 'z'), window = 2))",
    r"(result = O.portfolio_rolling(d2, ['a', 'z'], window=2))",
    r"(result = O.portfolio_rolling(d2, ["a", "z"]; window = 2))", inp = ein("optimize/ro_err_cols", c("d2"))),
  zeile("ro_err_short",
    r"(portfolio_rolling(d2, c('a', 'b'), window = 5))",
    r"(result = O.portfolio_rolling(d2, ['a', 'b'], window=5))",
    r"(result = O.portfolio_rolling(d2, ["a", "b"]; window = 5))", inp = ein("optimize/ro_err_short", c("d2")))))
TB("portfolio_cpcv", "Meldungen und Warnungen von portfolio_cpcv je Zeile (Eingabe -> Meldung bzw. Wert mit Warnung)", vor = VOR, zeilen = list(
  zeile("cp_partial",
    r"(portfolio_cpcv(R, methods = list(eq = list(method = 'equal'), bad = list(method = 'min_variance', upper = 0.2)), n_groups = 3, test_groups = 1))",
    r"(result = O.portfolio_cpcv(R, methods={'eq': {'method': 'equal'}, 'bad': {'method': 'min_variance', 'upper': 0.2}}, n_groups=3, test_groups=1))",
    r"(result = O.portfolio_cpcv(R; methods = SL.RList("eq" => SL.RList("method" => "equal"), "bad" => SL.RList("method" => "min_variance", "upper" => 0.2)), n_groups = 3, test_groups = 1))", print = TRUE, inp = ein("optimize/cp_partial", c("R"))),
  zeile("cp_warn26",
    r"(portfolio_cpcv(R, methods = list(a = list(upper = 26), b = list(method = 'equal')), n_groups = 3, test_groups = 1))",
    r"(result = O.portfolio_cpcv(R, methods={'a': {'upper': 26}, 'b': {'method': 'equal'}}, n_groups=3, test_groups=1))",
    r"(result = O.portfolio_cpcv(R; methods = SL.RList("a" => SL.RList("upper" => 26), "b" => SL.RList("method" => "equal")), n_groups = 3, test_groups = 1))", print = TRUE, inp = ein("optimize/cp_warn26", c("R"))),
  zeile("cp_err_allfail",
    r"(portfolio_cpcv(R, methods = list(a = list(method = 'min_variance', upper = 0.2))))",
    r"(result = O.portfolio_cpcv(R, methods={'a': {'method': 'min_variance', 'upper': 0.2}}))",
    r"(result = O.portfolio_cpcv(R; methods = SL.RList("a" => SL.RList("method" => "min_variance", "upper" => 0.2))))", inp = ein("optimize/cp_err_allfail", c("R"))),
  zeile("cp_err_method",
    r"(portfolio_cpcv(R, methods = c('equal', 'min_varianze')))",
    r"(result = O.portfolio_cpcv(R, methods=['equal', 'min_varianze']))",
    r"(result = O.portfolio_cpcv(R; methods = ["equal", "min_varianze"]))", inp = ein("optimize/cp_err_method", c("R"))),
  zeile("cp_err_groups",
    r"(portfolio_cpcv(R, n_groups = 3, test_groups = 3))",
    r"(result = O.portfolio_cpcv(R, n_groups=3, test_groups=3))",
    r"(result = O.portfolio_cpcv(R; n_groups = 3, test_groups = 3))", inp = ein("optimize/cp_err_groups", c("R"))),
  zeile("cp_err_ng",
    r"(portfolio_cpcv(R, n_groups = 2.5))",
    r"(result = O.portfolio_cpcv(R, n_groups=2.5))",
    r"(result = O.portfolio_cpcv(R; n_groups = 2.5))", inp = ein("optimize/cp_err_ng", c("R"))),
  zeile("cp_err_arg",
    r"(portfolio_cpcv(R, methods = list(a = list(method = 'equal', foo = 1))))",
    r"(result = O.portfolio_cpcv(R, methods={'a': {'method': 'equal', 'foo': 1}}))",
    r"(result = O.portfolio_cpcv(R; methods = SL.RList("a" => SL.RList("method" => "equal", "foo" => 1))))", inp = ein("optimize/cp_err_arg", c("R"))),
  zeile("cp_err_list",
    r"(portfolio_cpcv(R, methods = list(list(method = 'equal'))))",
    r"(result = O.portfolio_cpcv(R, methods=[{'method': 'equal'}]))",
    r"(result = O.portfolio_cpcv(R; methods = [SL.RList("method" => "equal")]))", inp = ein("optimize/cp_err_list", c("R"))),
  zeile("cp_err_entry",
    r"(portfolio_cpcv(R, methods = list(a = 'equal')))",
    r"(result = O.portfolio_cpcv(R, methods={'a': 'equal'}))",
    r"(result = O.portfolio_cpcv(R; methods = SL.RList("a" => "equal")))", inp = ein("optimize/cp_err_entry", c("R")))))
ref_done()

ref_schreiben()
