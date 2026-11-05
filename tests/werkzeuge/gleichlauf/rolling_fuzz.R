# tests/werkzeuge/gleichlauf/rolling_fuzz.R – Fuzz der Datums- und Fensterrechnung (seit 1.5.1): portfolio_rolling()
# (Python: Renditen je Fenster aus einmal aufbereiteten Kursen), result_analysis() (R: Monats-/Jahresschlüssel und
# Fensterlängen ganzzahlig statt format()/difftime je Tag), Periodenrenditen von dependence_analysis() und
# portfolio_optimize() (R: ISO-Woche und Monat ganzzahlig, .dep_returns)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/rolling_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul rolling_fuzz:
# Kursdaten (60 Tage bis 8 Jahre, täglich, Werktage oder lückenhaft, Jahre 1900 bis 2090, Start auch um Jahreswechsel
# und Monatsende) mit NA-Kursen, späten Starts, gelegentlich unzulässigen Kursen (<= 0) und unsortierten Zeilen;
#   45 % portfolio_rolling (Verfahren, Fenster, every, frequency, Grenzen),
#   35 % result_analysis (Liste von Reihen, Benchmark als Name oder Reihe, rolling_years, risk_free, inflation),
#   20 % portfolio_optimize bzw. dependence_analysis mit Kursdaten (week, month, day).
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261110)
ref_bereich("rolling_fuzz", alle = TRUE); ref_init("rolling_fuzz")

num <- function(v) sprintf("%.17g", v)
# Kursdaten: Spalten nm, n Kalendertage ab start, Lücken je Art
prices <- function(nm, n, start) {
  d <- data.frame(date = seq.Date(start, by = "day", length.out = n))
  art <- pick(c("tag", "werktag", "werktag", "luecken"))
  if (art == "werktag") d <- d[!format(d$date, "%u") %in% c("6", "7"), , drop = FALSE]
  if (art == "luecken") d <- d[sort(sample.int(n, max(2, round(n * runif(1, 0.3, 0.9))))), , drop = FALSE]
  rownames(d) <- NULL; m <- nrow(d)
  for (a in nm) {
    p <- round(runif(1, 5, 300) * cumprod(pmax(1e-3, 1 + rnorm(m, runif(1, -3e-4, 8e-4), runif(1, 0.002, 0.03)))), 4)
    if (m > 10 && coin(0.15)) { i0 <- sample(2:m, 1); p[i0:min(m, i0 + sample(0:20, 1))] <- NA }
    if (m > 10 && coin(0.1)) p[seq_len(sample(1:(m %/% 2), 1))] <- NA
    if (m > 10 && coin(0.03)) p[sample.int(m, 1)] <- pick(c(0, -5))
    d[[a]] <- p
  }
  d
}
vr <- function(v) sprintf("c(%s)", paste(v, collapse = ", "))
vp <- function(v) sprintf("[%s]", paste(v, collapse = ", "))
qr <- function(v) vr(sprintf("'%s'", v)); qp <- function(v) vp(sprintf("'%s'", v)); qj <- function(v) vp(sprintf("\"%s\"", v))

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  y0 <- if (coin(0.1)) pick(c(1900, 1970, 2000, 2090)) else sample(1960:2035, 1)
  start <- if (coin(0.3)) as.Date(sprintf("%d-12-%02d", y0, sample(20:31, 1))) else as.Date(sprintf("%d-01-01", y0)) + sample(0:364, 1)
  u <- runif(1)
  if (u < 0.45) {                                                           # portfolio_rolling
    na <- pick(c(2, 2, 3, 4)); nm <- c("a", "b", "c", "d")[seq_len(na)]
    d <- prices(nm, pick(c(200, 500, 800, 1200, 2000)), start)
    if (nrow(d) > 3 && coin(0.05)) { d <- d[sample.int(nrow(d)), ]; rownames(d) <- NULL }
    meth <- pick(c("min_variance", "min_variance", "equal", "inverse_vol", "max_sharpe", "risk_parity", "hrp", "max_diversification"))
    win <- pick(c(0.25, 0.5, 1, 1, 2)); ev <- pick(c("month", "quarter", "year")); fr <- pick(c("week", "week", "day", "month"))
    xr <- xp <- xj <- character(0)
    if (coin(0.15)) { xr <- ", upper = 0.7"; xp <- ", upper=0.7"; xj <- ", upper = 0.7" }
    fuzz_case(sprintf("r%05d", kk),
      r = sprintf("w <- portfolio_rolling(d, %s, method = '%s', window = %s, every = '%s', frequency = '%s'%s); list(w, attr(w, 'decision_rows'), attr(w, 'failed_dates'))",
                  qr(nm), meth, num(win), ev, fr, paste(xr, collapse = "")),
      py = sprintf("w = simlev.portfolio_rolling(d, %s, method='%s', window=%s, every='%s', frequency='%s'%s)\nresult = [w, w.attrs['decision_rows'], w.attrs['failed_dates']]",
                   qp(nm), meth, num(win), ev, fr, paste(xp, collapse = "")),
      jl = sprintf("w = SL.portfolio_rolling(d, %s; method = \"%s\", window = %s, every = \"%s\", frequency = \"%s\"%s)\nresult = [w, SL.attrs(w)[\"decision_rows\"], SL.attrs(w)[\"failed_dates\"]]",
                   qj(nm), meth, num(win), ev, fr, paste(xj, collapse = "")),
      inputs = list(d = d))
  } else if (u < 0.8) {                                                     # result_analysis
    ns <- pick(c(1, 2, 2, 3)); x <- list()
    for (s in seq_len(ns)) {
      dd <- prices("value", pick(c(60, 200, 400, 1000, 2500)), start + if (coin(0.3)) sample(-90:90, 1) else 0)
      dd <- dd[!is.na(dd$value) & dd$value > 0, , drop = FALSE]; rownames(dd) <- NULL
      x[[paste0("s", s)]] <- dd
    }
    ar <- ap <- aj <- character(0)
    add <- function(r, p, j) { ar <<- c(ar, r); ap <<- c(ap, p); aj <<- c(aj, j) }
    if (ns > 1 && coin(0.5)) add("benchmark = 's1'", "benchmark='s1'", "benchmark = \"s1\"")
    if (coin(0.6)) { ry <- num(pick(c(0.25, 0.5, 1, 3))); add(paste("rolling_years =", ry), paste0("rolling_years=", ry), paste("rolling_years =", ry)) }
    if (coin(0.3)) { rf <- num(pick(c(1, 2.5, -0.5))); add(paste("risk_free =", rf), paste0("risk_free=", rf), paste("risk_free =", rf)) }
    if (coin(0.2)) { inf <- num(pick(c(2, 0.5))); add(paste("inflation =", inf), paste0("inflation=", inf), paste("inflation =", inf)) }
    if (coin(0.15)) add("top_drawdowns = 3", "top_drawdowns=3", "top_drawdowns = 3")
    sep <- function(a, s) if (length(a)) paste0(s, paste(a, collapse = ", ")) else ""
    fuzz_case(sprintf("a%05d", kk),
      r = sprintf("result_analysis(x%s)", sep(ar, ", ")),
      py = sprintf("result = simlev.result_analysis(x%s)", sep(ap, ", ")),
      jl = sprintf("result = SL.result_analysis(x%s)", sep(aj, "; ")),
      inputs = list(x = x))
  } else {                                                                  # Periodenrenditen aus Kursdaten
    nm <- c("a", "b", "c")[seq_len(pick(c(2, 3)))]
    d <- prices(nm, pick(c(120, 400, 1500)), start)
    fr <- pick(c("week", "week", "month", "day"))
    if (coin(0.5)) {
      fuzz_case(sprintf("o%05d", kk),
        r = sprintf("portfolio_optimize(d, %s, method = 'min_variance', frequency = '%s')", qr(nm), fr),
        py = sprintf("result = simlev.portfolio_optimize(d, assets=%s, method='min_variance', frequency='%s')", qp(nm), fr),
        jl = sprintf("result = SL.portfolio_optimize(d; assets = %s, method = \"min_variance\", frequency = \"%s\")", qj(nm), fr),
        inputs = list(d = d))
    } else {
      fuzz_case(sprintf("d%05d", kk),
        r = sprintf("dependence_analysis(d, %s, frequency = '%s', copulas = FALSE, dcc = FALSE)", qr(nm), fr),
        py = sprintf("result = simlev.dependence_analysis(d, %s, frequency='%s', copulas=False, dcc=False)", qp(nm), fr),
        jl = sprintf("result = SL.dependence_analysis(d, %s; frequency = \"%s\", copulas = false, dcc = false)", qj(nm), fr),
        inputs = list(d = d))
    }
  }
}
ref_done(); ref_schreiben()
