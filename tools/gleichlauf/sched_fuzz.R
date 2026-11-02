# tools/gleichlauf/sched_fuzz.R – Datums-Fuzz der Vorbereitung (E17 Stufe 2: Termine, Kalender, Flags im Kern)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_MODULE_DIR=<ordner> Rscript tools/gleichlauf/sched_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Modulreferenzen (golden/modules/ref_tools.R) als Modul sched_fuzz:
#   - d-Fälle (gut die Hälfte): calculate_dates_flags() direkt (R intern, Python simlev.engine, Julia SL) über
#     Tage der Jahre 1601 bis 2399 (Schaltjahrregeln), lückenlos oder als Auswahl, mit allen Einheiten,
#     Schritten (auch 0, negativ, gebrochen, sehr groß), Tagen 1 bis 31 (auch doppelt), Ankern, Startdaten
#     (vor, im und nach dem Zeitraum), skip_start, liquidate und value; Monatsarithmetik wie seq.Date.
#   - s-Fälle: simulation() mit Schwerpunkt Kalender über Tage der Jahre 1800 bis 2200: Monatsenden und
#     Schalttage, Lücken (aufgefüllte Tage, Verschieben von Terminen), späte Starts, Sparplan und Rebalancing
#     mit Tagen, Ankern, Startdaten und skip, Ereignis-Spalte, Freibetrag mit beliebigem Tag (auch 00-15,
#     02-30), Jahreswechsel mit Steuer, Splits, liquidate, details.
#
# Prüfung (tools/gleichlauf/run.sh, Schritt 5): Referenz aus R 1.3.0 (R_LIBS=/home/claude/rlib130), R neu
# mit tools/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit compare_reference gegen die Referenz.
source("golden/modules/ref_tools.R")
source("golden/tools/blocks_from_flat.R")
local({   # Code-Erzeuger aus gen_engine.R (em, .args, sim_code), ohne dessen Fälle
  ex <- parse("golden/modules/gen_engine.R", keep.source = FALSE)
  want <- c("V", ".num1", ".str1", "em", ".args", "sim_code")
  for (e in ex) if (is.call(e) && identical(e[[1L]], as.name("<-")) && is.name(e[[2L]]) && as.character(e[[2L]]) %in% want)
    eval(e, envir = globalenv())
})
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261102)
ref_init("sched_fuzz")
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p
day0 <- function(y1, y2) as.numeric(as.Date(sprintf("%d-01-01", y1))) +
  sample.int(as.numeric(as.Date(sprintf("%d-01-01", y2)) - as.Date(sprintf("%d-01-01", y1))), 1) - 1
# Tage fuer days: oft Monatsenden, auch doppelt
rdays <- function() {
  k <- pick(c(1, 1, 2, 3, 4))
  x <- sample(c(1:31, 28:31, 28:31), k, replace = TRUE)
  if (coin(0.1)) x <- c(x, x[1])
  as.numeric(x)
}
# Startdatum relativ zum Zeitraum [z0, z1]
rstart <- function(z0, z1) {
  u <- runif(1)
  if (u < 0.45) NULL
  else if (u < 0.75) format(as.Date(z0 + sample(0:(z1 - z0), 1)))
  else if (u < 0.97) format(as.Date(z0 - sample(1:2000, 1)))
  else format(as.Date(z1 + sample(1:400, 1)))
}

nd <- round(N * 0.55)
for (k in seq_len(nd)) {   # d-Fälle: calculate_dates_flags()
  set.seed(seed0 + k)
  n <- pick(c(1, 2, 28, 29, 30, 31, 59, 60, 61, 90, 120, 365, 366, 400, 731, 731, 1500, 1500, 3000, 3000))
  z0 <- day0(1601, 2399)
  if (coin(0.15)) z0 <- as.numeric(as.Date(sprintf("%d-%02d-01", sample(1601:2399, 1), sample(1:12, 1)))) - sample(0:2, 1)
  z <- z0 + seq_len(n) - 1
  if (n > 3 && coin(0.15)) z <- sort(unique(c(z[1], z[n], sample(z, sample(1:(n - 1), 1)))))
  dd <- as.Date(z)
  a <- list(mode = coin(0.96),
            span = if (coin(0.15)) NULL else pick(list(1, 1, 2, 3, 4, sample(5:13, 1), 100, 1000, 1.5, 2.5, 0, -1)),
            unit = if (coin(0.03)) NULL else pick(c("month", "quarter", "year")),
            days = if (coin(0.4)) NULL else rdays())
  if (!is.null(a$span) && a$span <= 0 && coin(0.7)) a$span <- 1   # 0 und negativ selten
  value <- if (coin(0.85)) NULL else pick(list(100, 100, 0, -1))
  anchor <- pick(c("start", "end")); st <- rstart(min(z), max(z))
  # Schritt <= 0 mit Start nach dem Zeitraum: R liefert Perioden nach dem letzten Tag (seq rueckwaerts), die
  # Ports melden "wrong sign" (ueber simulation() nicht erreichbar); hier nicht erzeugt
  if (!is.null(a$span) && a$span <= 0 && !is.null(st) && as.Date(st) > max(dd)) st <- NULL
  skip <- coin(0.3); liq <- coin(0.3)
  code <- function(L) {
    lg <- function(x) em(x, L)
    switch(L,
      r = sprintf("result <- SimLev:::calculate_dates_flags(mode = %s, span = %s, unit = %s, days = %s, dates = dd, value = %s, anchor = %s, start_date = %s, skip_start = %s, liquidate = %s)",
                  lg(a$mode), lg(a$span), lg(a$unit), lg(a$days), lg(value), lg(anchor), lg(st), lg(skip), lg(liq)),
      py = sprintf("result = simlev.engine.calculate_dates_flags(%s, %s, %s, %s, dd, value=%s, anchor=%s, start_date=%s, skip_start=%s, liquidate=%s)",
                   lg(a$mode), lg(a$span), lg(a$unit), lg(a$days), lg(value), lg(anchor), lg(st), lg(skip), lg(liq)),
      jl = sprintf("result = SL.calculate_dates_flags(%s, %s, %s, %s, dd; value = %s, anchor = %s, start_date = %s, skip_start = %s, liquidate = %s)",
                   lg(a$mode), lg(a$span), lg(a$unit), lg(a$days), lg(value), lg(anchor), lg(st), lg(skip), lg(liq)))
  }
  ref_case(sprintf("d%05d", k), r = code("r"), py = code("py"), jl = code("jl"), inputs = list(dd = dd))
}

classes <- c("etf", "etf", "etn", "etc", "certificate")
for (k in seq_len(N - nd)) {   # s-Fälle: simulation() mit Schwerpunkt Kalender
  set.seed(seed0 + 100000 + k)
  n <- pick(c(1, 2, 3, 31, 60, 200, 400, 800, 1500))
  start <- as.Date(day0(1800, 2200))
  if (coin(0.25)) start <- as.Date(sprintf("%d-%02d-%02d", sample(1800:2199, 1), sample(1:12, 1), sample(27:28, 1)))
  if (coin(0.1)) start <- as.Date(sprintf("%d-12-%02d", sample(1800:2199, 1), sample(20:31, 1)))
  d <- data.frame(date = seq.Date(start, by = "day", length.out = n))
  na <- pick(c(1, 2, 2))
  for (j in seq_len(na)) d[[LETTERS[j]]] <- round(runif(1, 20, 300) * cumprod(1 + rnorm(n, 2e-4, 0.015)), 4)
  sh <- if (na == 1) 1 else pick(list(c(0.5, 0.5), c(0.7, 0.3)))
  st <- lapply(seq_len(na), function(j) {
    x <- list(asset_class = pick(classes), trading = "bnh", share = sh[j])
    if (j > 1 && n > 10 && coin(0.2)) x$start <- format(start + sample(1:(n - 2), 1))
    x
  })
  names(st) <- LETTERS[seq_len(na)]
  if (n > 10 && coin(0.4)) {   # Lücken, oft ganze Wochenenden und Monatsenden
    gap <- if (coin(0.5)) as.POSIXlt(d$date)$wday %in% c(0, 6) else runif(n) < runif(1, 0.1, 0.6)
    if (coin(0.3)) gap <- gap | as.POSIXlt(d$date + 1)$mday == 1
    gap[c(1, n)] <- FALSE
    d <- d[!gap, , drop = FALSE]; rownames(d) <- NULL
  }
  a <- list(start_value = pick(c(1e4, 25000)))
  if (coin(0.7)) {
    a$dca_mode <- TRUE; a$dca_value <- pick(c(100, 500)); a$dca_unit <- pick(c("month", "quarter", "year"))
    a$dca_span <- pick(c(1, 1, 2, 3, 4))
    if (coin(0.5)) a$dca_days <- unique(rdays())
    if (coin(0.4)) a$dca_anchor <- pick(c("start", "end"))
    if (coin(0.2)) a$dca_skip <- TRUE
    if (coin(0.3)) a$dca_start <- format(start + sample(-800:max(0, n - 1), 1))
  }
  if (coin(0.6)) {
    a$balance_mode <- TRUE; a$balance_unit <- pick(c("month", "quarter", "year"))
    if (coin(0.4)) a$balance_span <- pick(c(1, 2, 3, 1.5, 2.5))
    if (coin(0.4)) a$balance_days <- unique(rdays())
    if (coin(0.3)) a$balance_anchor <- pick(c("start", "end"))
    if (coin(0.2)) a$balance_skip <- TRUE
    if (coin(0.2)) a$balance_start <- format(start + sample(-800:max(0, n - 1), 1))
    if (coin(0.3)) a$balance_thresh <- pick(c(1, 5))
  }
  nr <- nrow(d)
  if (nr > 3 && coin(0.15)) { d$ev <- runif(nr) < 0.05; a$event_col <- "ev"; a$event_mode <- pick(c("additional", "replace")) }
  if (coin(0.15)) { a$split_mode <- TRUE; a$split_thresh <- pick(list(c(50, 150), c(20, 400))) }
  if (coin(0.55)) {
    a$tax_mode <- "person"
    if (coin(0.4)) a$base_rate <- pick(c(1.5, 2.55))
    if (coin(0.35)) {
      a$harvest_mode <- TRUE
      a$harvest_day <- pick(c(sprintf("%02d-%02d", sample(1:12, 1), sample(1:31, 1)), "00-15", "02-30", "12-30", "01-01"))
      if (a$harvest_day >= "12-31") a$harvest_day <- "12-30"
    }
  }
  if (coin(0.15)) a$details <- TRUE
  if (coin(0.4)) a$liquidate <- TRUE
  bl <- blocks_from_flat(a)
  s <- do.call(create_strategy, lapply(st, function(x) do.call(asset_config, x)))
  ref_case(sprintf("s%05d", k), r = sim_code("d", "s", bl, "r"), py = paste0("result = ", sim_code("d", "s", bl, "py")),
           jl = paste0("result = ", sim_code("d", "s", bl, "jl")), inputs = list(d = d, s = s))
}
ref_done()
