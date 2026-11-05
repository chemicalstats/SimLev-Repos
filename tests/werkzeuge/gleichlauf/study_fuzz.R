# tests/werkzeuge/gleichlauf/study_fuzz.R – Fuzz der Studien über simulation() (seit 1.5.1: Prüf-Cache je Studie,
# .sim_study/.sim_memo_* in R, _StudyCache in Python, @study in Julia)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/study_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul study_fuzz:
# param_search, sensitivity_grid, sensitivity_rebalancing, planning_lumpsum_vs_dca, sensitivity_leverage und
# bootstrap_study mit kleinen Größen; Daten mit Meldungen je Lauf (unsortierte Zeilen, Datum als Text, NA-Kurse,
# später Start), Fehlern je Lauf (doppelte Tage, ungültige Kurse, ungültige Strategie) und Warnungen je Lauf;
# geschachtelt (simulation() im builder von param_search). Neben Ergebnis und Warnungen hält r_conds alle Meldungen
# und Warnungen in Reihenfolge und Anzahl fest (nur R, verglichen R neu gegen R 1.5.0 mit sim_fuzz_cmp.py).
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261111)
ref_bereich("study_fuzz", alle = TRUE); ref_init("study_fuzz")

num <- function(v) sprintf("%.17g", v)

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  n <- pick(c(400, 800, 1200))
  start <- as.Date(sprintf("%d-01-01", sample(1990:2030, 1))) + sample(0:364, 1)
  d <- data.frame(date = seq.Date(start, by = "day", length.out = n))
  d$A <- round(100 * cumprod(1 + rnorm(n, 3e-4, 0.012)), 4); d$B <- round(50 * cumprod(1 + rnorm(n, 1e-4, 0.004)), 4)
  st_r <- "st <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))"
  st_p <- "st = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))"
  st_j <- 'st = SL.create_strategy("A" => SL.asset_config("etf", "bnh", 0.6), "B" => SL.asset_config("etf", "bnh", 0.4))'
  art <- pick(c("ok", "ok", "ok", "unsortiert", "text", "na", "spaet", "doppelt", "kurs", "strategie"))
  if (art == "unsortiert") { d <- d[c(2:n, 1), ]; rownames(d) <- NULL }
  if (art == "text") d$date <- format(d$date)
  if (art == "na") d$A[sample(10:(n - 1), 3)] <- NA
  if (art == "spaet") d$B[1:sample(5:50, 1)] <- NA
  if (art == "doppelt") d$date[n] <- d$date[n - 1]
  if (art == "kurs") d$B[sample(10:n, 1)] <- -1
  if (art == "strategie") {
    st_r <- "st <- list(A = list(asset_class = 'etf', trading = 'bnh', share = 0.6), B = list(asset_class = 'etf', trading = 'xx', share = 0.4))"
    st_p <- "st = {'A': {'asset_class': 'etf', 'trading': 'bnh', 'share': 0.6}, 'B': {'asset_class': 'etf', 'trading': 'xx', 'share': 0.4}}"
    st_j <- 'st = SL.RList("A" => SL.RList("asset_class" => "etf", "trading" => "bnh", "share" => 0.6), "B" => SL.RList("asset_class" => "etf", "trading" => "xx", "share" => 0.4))'
  }
  if (coin(0.15)) {
    st_r <- sub("'etf', 'bnh', 0.4\\)", "'etf', 'bnh', 0.45)", st_r)                    # Gewichte ungleich 1
    st_p <- sub("share=0.4\\)", "share=0.45)", st_p); st_j <- sub("0.4\\)\\)$", "0.45))", st_j)
  }
  kind <- pick(c("ps", "ps", "sg", "sr", "pl", "lv", "bs", "nest", "nest"))
  if (kind == "ps") {
    un <- pick(list(c("month", "quarter"), c("year"), c("quarter", "year")))
    th <- pick(list(c(2, 5), c(5), c(1, 5, 10)))
    ra <- sprintf("ps <- param_search(d, space = param_space(rebalance.thresh = c(%s), rebalance.unit = c(%s)), strategy = st, sim_args = list(rebalance = rebalance_plan(span = 1, unit = 'month')), cores = 1); ps$elapsed <- 0; ps$results$elapsed <- 0; ps",
                  paste(th, collapse = ", "), paste0("'", un, "'", collapse = ", "))
    pa <- sprintf("ps = simlev.param_search(d, space=simlev.param_space(**{'rebalance.thresh': [%s], 'rebalance.unit': [%s]}), strategy=st, sim_args={'rebalance': simlev.rebalance_plan(span=1, unit='month')}, cores=1); ps['elapsed'] = 0; ps['results']['elapsed'] = 0; result = ps",
                  paste(th, collapse = ", "), paste0("'", un, "'", collapse = ", "))
    ja <- sprintf('ps = SL.param_search(d; space = SL.param_space("rebalance.thresh" => [%s], "rebalance.unit" => [%s]), strategy = st, sim_args = SL.RList("rebalance" => SL.rebalance_plan(; span = 1, unit = "month")), cores = 1); ps["elapsed"] = 0; ps["results"]["elapsed"] = zeros(SL.nrow(ps["results"])); result = ps',
                  paste(sprintf("%.1f", th), collapse = ", "), paste0('"', un, '"', collapse = ", "))
  } else if (kind == "sg") {
    ra <- "sensitivity_grid(d, st, list(rebalance.unit = c('month', 'quarter', 'year')), sim_args = list(rebalance = rebalance_plan(span = 1)))"
    pa <- "result = simlev.sensitivity_grid(d, st, {'rebalance.unit': ['month', 'quarter', 'year']}, sim_args={'rebalance': simlev.rebalance_plan(span=1)})"
    ja <- 'result = SL.sensitivity_grid(d, st, SL.RList("rebalance.unit" => ["month", "quarter", "year"]); sim_args = SL.RList("rebalance" => SL.rebalance_plan(; span = 1)))'
  } else if (kind == "sr") {
    ra <- "sensitivity_rebalancing(d, st, frequencies = list(monthly = c('month', 1), yearly = c('year', 1)), bands = c(NA, 5))"
    pa <- "result = simlev.sensitivity_rebalancing(d, st, frequencies={'monthly': ('month', 1), 'yearly': ('year', 1)}, bands=[None, 5])"
    ja <- 'result = SL.sensitivity_rebalancing(d, st; frequencies = ["monthly" => ("month", 1), "yearly" => ("year", 1)], bands = [SL.NA, 5.0])'
  } else if (kind == "pl") {
    ra <- "x <- planning_lumpsum_vs_dca(d, st, amount = 6000, months = 6, horizon = 1, step = 60); list(x, attr(x, 'summary'))"
    pa <- "x = simlev.planning_lumpsum_vs_dca(d, st, amount=6000, months=6, horizon=1, step=60); result = [x, x.attrs['summary']]"
    ja <- 'x = SL.planning_lumpsum_vs_dca(d, st; amount = 6000, months = 6, horizon = 1, step = 60); result = [x, SL.attrs(x)["summary"]]'
  } else if (kind == "lv") {
    ra <- "sensitivity_leverage(d, 'A', leverages = c(1, 2), rate = 2, expense = 0.5)"
    pa <- "result = simlev.sensitivity_leverage(d, 'A', leverages=[1, 2], rate=2, expense=0.5)"
    ja <- 'result = SL.sensitivity_leverage(d, "A"; leverages = [1.0, 2.0], rate = 2, expense = 0.5)'
  } else if (kind == "bs") {
    nb <- pick(c(2, 4)); sd0 <- sample(1:99, 1)
    ra <- sprintf("s <- bootstrap_study(d, bootstrap_config(c(A = 'A', B = 'B'), input = 'prices'), 'stationary', n = %d, path_length = 250, seed = %d, progress = FALSE, strategies = list(a = st)); s$elapsed <- 0; s", nb, sd0)
    pa <- sprintf("s = simlev.bootstrap_study(d, simlev.bootstrap_config({'A': 'A', 'B': 'B'}, input='prices'), 'stationary', n=%d, path_length=250, seed=%d, progress=False, strategies={'a': st}); s['elapsed'] = 0; result = s", nb, sd0)
    ja <- sprintf('s = SL.bootstrap_study(d, SL.bootstrap_config((A = "A", B = "B"), input = "prices"), "stationary"; n = %d, path_length = 250, seed = %d, progress = false, strategies = (a = st,)); s["elapsed"] = 0; result = s', nb, sd0)
  } else {                                                                    # geschachtelt: simulation() im builder
    ra <- "b <- function(p) { r0 <- simulation(d, st, rebalance = rebalance_plan(unit = p$u)); list(strategy = st, rebalance = rebalance_plan(unit = p$u)) }; ps <- param_search(d, b, param_space(u = c('month', 'year')), cores = 1); ps$elapsed <- 0; ps$results$elapsed <- 0; ps"
    pa <- "def b(p):\n    r0 = simlev.simulation(d, st, rebalance=simlev.rebalance_plan(unit=p['u']))\n    return {'strategy': st, 'rebalance': simlev.rebalance_plan(unit=p['u'])}\nps = simlev.param_search(d, b, simlev.param_space(u=['month', 'year']), cores=1); ps['elapsed'] = 0; ps['results']['elapsed'] = 0; result = ps"
    ja <- 'b = p -> (r0 = SL.simulation(d, st; rebalance = SL.rebalance_plan(; unit = p["u"])); SL.RList("strategy" => st, "rebalance" => SL.rebalance_plan(; unit = p["u"])))\nps = SL.param_search(d, b, SL.param_space(u = ["month", "year"]); cores = 1); ps["elapsed"] = 0; ps["results"]["elapsed"] = zeros(SL.nrow(ps["results"])); result = ps'
  }
  fuzz_case(sprintf("%s%05d", kind, kk), r = paste0(st_r, "\n", ra), py = paste0(st_p, "\n", pa), jl = paste0(st_j, "\n", ja),
            inputs = list(d = d), conds = TRUE)
}
ref_done(); ref_schreiben()
