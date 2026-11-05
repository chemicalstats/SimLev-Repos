# tests/werkzeuge/gleichlauf/cal_fuzz.R – Fuzz der Kalenderauffüllung von simulation() (seit 1.6.0 im Kern,
# core/slc_prep.cpp sl_cal_index/sl_cal_fill_*; bis 1.5.2 R merge(), Python und Julia je eine Schleife).
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/cal_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul cal_fuzz:
# lückenhafte Kursdaten (Werktage, zufällige Lücken, lange Lücken; 10 bis 2.000 Kalendertage, Jahre 1990 bis 2030)
# mit 1 bis 3 Assets (Kaufen und Halten oder Signale), NA- und NaN-Kursen, führenden NA, logischen Signalen mit NA,
# Zusatzspalten (ganze Zahlen, Text, logisch, Faktor; Faktor und ganzzahlig gespeichertes Datum über den bisherigen
# Weg), Sparplan und Rebalancing. Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261113)
ref_bereich("cal_fuzz", alle = TRUE); ref_init("cal_fuzz")
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p

fuzz_case <- function(id, r, py, jl, inputs) {
  ref_case(id, r = r, py = py, jl = jl, inputs = inputs)
  if (!.ref_in_subset(id)) return(invisible(NULL))
  env <- new.env(parent = globalenv())
  for (k in names(inputs)) assign(k, inputs[[k]], envir = env)
  dp <- function(x) if (is.null(x)) "NULL" else paste(deparse(x), collapse = " ")
  wc <- character(0); ec <- NULL
  invisible(capture.output(tryCatch(withCallingHandlers(eval(parse(text = r), envir = env),
    warning = function(w) { wc <<- c(wc, dp(conditionCall(w))); invokeRestart("muffleWarning") },
    message = function(m) invokeRestart("muffleMessage")),
    error = function(e) ec <<- dp(conditionCall(e)))))
  ref_case_extra(list(r_calls = list(warnings = as.list(wc), error = ec)))
}

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  n <- pick(c(10, 25, 60, 200, 400, 1000, 2000))
  start <- as.Date("1990-01-01") + sample(0:14600, 1)
  cal <- seq.Date(start, by = "day", length.out = n)
  keep <- switch(pick(1:3),
    as.POSIXlt(cal)$wday %in% 1:5,                                   # Werktage
    runif(n) > runif(1, 0.05, 0.6),                                  # zufällige Lücken
    { k <- rep(TRUE, n); if (n > 8) { i0 <- sample(2:(n - 3), 1); k[i0:min(n - 1, i0 + sample(1:40, 1))] <- FALSE }; k })
  keep[c(1, n)][coin(0.5)] <- TRUE
  if (sum(keep) < 1) keep[1] <- TRUE
  d <- data.frame(date = cal[keep]); m <- nrow(d)
  na <- pick(c(1, 1, 2, 3)); nm <- LETTERS[seq_len(na)]
  sig <- vapply(seq_len(na), function(j) coin(0.3), NA)
  for (j in seq_len(na)) {
    p <- round(runif(1, 5, 300) * cumprod(pmax(1e-3, 1 + rnorm(m, 3e-4, 0.015))), 4)
    if (m > 4 && coin(0.3)) p[sample.int(m, max(1, m %/% 9))] <- NA
    if (m > 4 && coin(0.1)) p[sample.int(m, 1)] <- NaN
    if (m > 4 && j > 1 && coin(0.15)) p[seq_len(sample(1:(m - 2), 1))] <- NA
    if (j == 1 && coin(0.9)) p[1] <- round(runif(1, 5, 300), 4)      # meist ein Kurs am ersten Tag
    d[[nm[j]]] <- p
    if (sig[j]) {
      b <- runif(m) < 0.1; s <- runif(m) < 0.1
      if (coin(0.4)) b[sample.int(m, max(1, m %/% 10))] <- NA
      d[[paste0("b", j)]] <- b; d[[paste0("s", j)]] <- s
    }
  }
  if (coin(0.3)) { v <- sample(c(1L, 5L, -3L), m, TRUE); if (coin(0.5)) v[sample.int(m, 1)] <- NA; d$xi <- v }
  if (coin(0.2)) d$xc <- sample(c("x", "y", NA), m, TRUE)
  if (coin(0.3)) d$xl <- sample(c(TRUE, FALSE, NA), m, TRUE)
  if (coin(0.08)) d$xf <- factor(sample(c("u", "v"), m, TRUE))
  if (coin(0.08)) d$date <- structure(as.integer(unclass(d$date)), class = "Date")
  shares <- if (na == 1) 1 else round(rep(1 / na, na), 4)
  shares[na] <- 1 - sum(shares[-na])
  one <- function(j, L) {
    tr <- if (sig[j]) "signal" else "bnh"
    sb <- if (sig[j]) switch(L, r = sprintf(", signal_buy = 'b%d', signal_sell = 's%d'", j, j),
                             py = sprintf(", signal_buy='b%d', signal_sell='s%d'", j, j),
                             jl = sprintf(", signal_buy = \"b%d\", signal_sell = \"s%d\"", j, j)) else ""
    switch(L, r = sprintf("%s = asset_config('etf', '%s', share = %.17g%s)", nm[j], tr, shares[j], sb),
           py = sprintf("%s=simlev.asset_config(asset_class='etf', trading='%s', share=%.17g%s)", nm[j], tr, shares[j], sb),
           jl = sprintf("\"%s\" => SL.asset_config(; asset_class = \"etf\", trading = \"%s\", share = %.17g%s)", nm[j], tr, shares[j], sb))
  }
  body <- function(L) paste(vapply(seq_len(na), one, "", L = L), collapse = ", ")
  dca <- coin(0.4); reb <- coin(0.4)
  opt <- list(r = paste0(if (dca) ", dca = dca_plan(value = 100, span = 1)" else "", if (reb) ", rebalance = rebalance_plan(unit = 'quarter')" else ""),
              py = paste0(if (dca) ", dca=simlev.dca_plan(value=100, span=1)" else "", if (reb) ", rebalance=simlev.rebalance_plan(unit='quarter')" else ""),
              jl = paste0(if (dca) ", dca = SL.dca_plan(; value = 100, span = 1)" else "", if (reb) ", rebalance = SL.rebalance_plan(; unit = \"quarter\")" else ""))
  fuzz_case(sprintf("c%05d", kk),
    r = sprintf("simulation(d, create_strategy(%s), start_value = 10000%s)", body("r"), opt$r),
    py = sprintf("result = simlev.simulation(d, simlev.create_strategy(%s), start_value=10000%s)", body("py"), opt$py),
    jl = sprintf("result = SL.simulation(d, SL.create_strategy(%s); start_value = 10000%s)", body("jl"), opt$jl),
    inputs = list(d = d))
}
ref_done(); ref_schreiben()
