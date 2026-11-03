# tests/gleichlauf/sim_fuzz.R – Zufallsfälle über simulation() mit allen Bausteinen (E17, ab Stufe 1a)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/gleichlauf/sim_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/erzeugen/ref_tools.R) als Bereich sim_fuzz in
# <SIMLEV_FAELLE_DIR>/sim_fuzz.jsonl.gz: Ergebnis als Baum, Konsolenausgabe (details), print(), Warnungen und Fehlertext, dazu
# R-, Python- und Julia-Code. Die Fälle mischen Daten (Lücken, NA-Kurse, späte Starts, Signale logisch und
# numerisch, auch mit NA), Strategien (alle Assetklassen, Signal- und Buy-and-Hold-Assets, Spreads,
# Teilfreistellung, Fonds-Wrapper) und Bausteine (Kosten, Sparplan, Rebalancing mit Schwellen und
# Ereignissen, Splits, Steuer mit Kirchensteuer, Günstigerprüfung, Tarif, Basiszinsspalte, Freibetrag),
# details (seit E17 Stufe 1c in allen Fällen möglich, gut 30 %), fractions, liquidate und risk_free. Gut 40 % der
# Fälle laufen ohne Steuer und Splits. Am Ende drei feste Zusatzfälle (x00001–x00003): Abbruch von
# .perform_asset_split (ratio <= 0), weil der Kurs nach einem Split ohne Bestand auf 0 unterläuft.
#
# Prüfung (tests/gleichlauf/run.sh, Schritt 5): die Referenz erzeugt R 1.3.0 (R_LIBS=/home/claude/rlib130 bzw.
# SIMLEV_FUZZ_REFLIB), das aktuelle R schreibt dieselben Fälle in einen zweiten Ordner; Vergleich R neu gegen
# die Referenz mit tests/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/erzeugen/ref_tools.R")
source("tests/erzeugen/blocks_from_flat.R")
local({   # Code-Erzeuger aus tests/erzeugen/engine.R (V, em, .args, sim_code), ohne dessen Fälle
  ex <- parse("tests/erzeugen/engine.R", keep.source = FALSE)
  want <- c("V", ".num1", ".str1", "em", ".args", "sim_code")
  for (e in ex) if (is.call(e) && identical(e[[1L]], as.name("<-")) && is.name(e[[2L]]) && as.character(e[[2L]]) %in% want)
    eval(e, envir = globalenv())
})
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261101)
ref_bereich("sim_fuzz", alle = TRUE); ref_init("sim_fuzz")

pick <- function(x) x[[sample.int(length(x), 1L)]]

# Fall schreiben (ref_case) und die Aufrufe der Warnungen und des Fehlers (nur R; deparse) als Feld r_calls
# nachtragen: der Vergleich R neu gegen R 1.3.0 prüft damit auch die Aufrufe der Bedingungen
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
  # C19: Bedingungen aus dem Kern tragen den Aufruf von simulation() (bis 1.3.0 einen festen Ausdruck der Phase);
  # sim_call = erster Aufruf von simulation() im Code (deparse), Sollwert dieser Kopfzeilen in sim_fuzz_cmp.py
  fs <- function(e) {
    if (!is.call(e)) return(NULL)
    if (identical(e[[1L]], as.name("simulation"))) return(e)
    for (i in seq_along(e)[-1L]) { x <- tryCatch(fs(e[[i]]), error = function(err) NULL); if (!is.null(x)) return(x) }
    NULL
  }
  sc <- NULL
  for (e in parse(text = r, keep.source = FALSE)) if (is.null(sc)) sc <- fs(e)
  ref_case_extra(list(r_calls = list(warnings = as.list(wc), error = ec, sim_call = dp(sc))))
}
coin <- function(p) runif(1) < p

# Fonds-Wrapper: innere Strategie aus den Spalten A und B, Code je Sprache
wrap_code <- function(fee, perf, reb) {
  rb <- if (reb) list(r = ", rebalance = rebalance_plan(unit = 'quarter')", py = ", rebalance=simlev.rebalance_plan(unit='quarter')",
                      jl = ", rebalance = SL.rebalance_plan(; unit = \"quarter\")") else list(r = "", py = "", jl = "")
  list(
    r = sprintf("inner <- create_strategy(A = asset_config('etf', 'bnh', 0.6), B = asset_config('etf', 'bnh', 0.4))\nwz <- wrapper_config(inner%s, costs = funds_costs(%s, %s))",
                rb$r, fee, perf),
    py = sprintf("inner = simlev.create_strategy(A=simlev.asset_config(asset_class='etf', trading='bnh', share=0.6), B=simlev.asset_config(asset_class='etf', trading='bnh', share=0.4))\nwz = simlev.wrapper_config(inner%s, costs=simlev.funds_costs(fee=%s, performance_fee=%s))",
                 rb$py, fee, perf),
    jl = sprintf("inner = SL.create_strategy(\"A\" => SL.asset_config(\"etf\", \"bnh\", 0.6), \"B\" => SL.asset_config(\"etf\", \"bnh\", 0.4))\nwz = SL.wrapper_config(inner; costs = SL.funds_costs(%s, %s)%s)",
                 fee, perf, rb$jl))
}
# Strategie als Code (für Fälle mit Wrapper; sonst Eingabeobjekt)
strat_code <- function(st) {
  one <- function(nm, a, L) {
    kv <- list(asset_class = a$asset_class, trading = a$trading, share = a$share, spread = a$spread,
               partial_exemption = a$partial_exemption, start = a$start, signal_buy = a$signal_buy,
               signal_sell = a$signal_sell)
    kv <- kv[!vapply(kv, is.null, NA)]   # nicht gesetzte Angaben (Voreinstellung)
    parts <- vapply(names(kv), function(k) switch(L, py = sprintf("%s=%s", k, em(kv[[k]], L)),
                                                  sprintf("%s = %s", k, em(kv[[k]], L))), "")
    w <- isTRUE(a$wrapper)
    switch(L,
      r = sprintf("%s = asset_config(%s%s)", nm, paste(parts, collapse = ", "), if (w) ", wrapper = wz" else ""),
      py = sprintf("%s=simlev.asset_config(%s%s)", nm, paste(parts, collapse = ", "), if (w) ", wrapper=wz" else ""),
      jl = sprintf("\"%s\" => SL.asset_config(; %s%s)", nm, paste(parts, collapse = ", "), if (w) ", wrapper = wz" else ""))
  }
  lapply(c(r = "r", py = "py", jl = "jl"), function(L) {
    body <- paste(vapply(names(st), function(nm) one(nm, st[[nm]], L), ""), collapse = ", ")
    switch(L, r = sprintf("s <- create_strategy(%s)", body), py = sprintf("s = simlev.create_strategy(%s)", body),
           jl = sprintf("s = SL.create_strategy(%s)", body))
  })
}

classes <- c("etf", "etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable")
for (k in seq_len(N)) {
  set.seed(seed0 + k)
  id <- sprintf("z%05d", k)
  n <- pick(c(1, 2, 3, 15, 40, 120, 250, 400, 400, 800, 800, 1500))
  start <- as.Date("1996-01-01") + sample(0:9800, 1)
  if (coin(0.1)) start <- as.Date(sprintf("%d-12-%02d", sample(1996:2022, 1), sample(20:31, 1)))
  na <- pick(c(1, 2, 2, 3))
  d <- data.frame(date = seq.Date(start, by = "day", length.out = n))
  for (j in seq_len(na)) {
    lev <- pick(c(1, 1, 1, 3)); mu <- runif(1, -5e-4, 1e-3); sg <- runif(1, 0.002, 0.03)
    p <- round(runif(1, 5, 300) * cumprod(pmax(1e-3, 1 + lev * rnorm(n, mu, sg))), 4)
    if (n > 5 && coin(0.12)) { i0 <- sample(2:n, 1); p[i0:min(n, i0 + sample(0:6, 1))] <- NA }   # NA-Kurse
    if (n > 5 && j > 1 && coin(0.08)) p[seq_len(sample(1:(n - 2), 1))] <- NA                     # späte erste Kurse
    d[[LETTERS[j]]] <- p
  }
  nm <- LETTERS[seq_len(na)]
  st <- list()
  shares <- switch(na, list(1), list(c(0.5, 0.5), c(0.6, 0.4), c(0.75, 0.25)), list(c(0.5, 0.3, 0.2), c(0.4, 0.4, 0.2)))
  shares <- pick(shares)
  for (j in seq_len(na)) {
    sig <- coin(0.3)
    a <- list(asset_class = pick(classes), trading = if (sig) "signal" else "bnh", share = shares[j],
              spread = pick(list(NULL, 0, 0.1, 0.5)), partial_exemption = pick(list(NULL, 0, 15, 30)))
    if (j > 1 && n > 10 && coin(0.15)) a$start <- format(start + sample(1:(n - 2), 1))
    if (sig) {
      a$signal_buy <- paste0("b", j); a$signal_sell <- paste0("s", j)
      pb <- pick(c(0.02, 0.1, 0.5)); ps <- pick(c(0.02, 0.1, 0.5))
      b <- runif(n) < pb; s <- runif(n) < ps
      if (coin(0.15)) { b[sample.int(n, max(1, n %/% 20))] <- NA; s[sample.int(n, max(1, n %/% 20))] <- NA }
      if (coin(0.15)) { b <- as.numeric(b); s <- as.numeric(s) }
      d[[a$signal_buy]] <- b; d[[a$signal_sell]] <- s
    }
    st[[nm[j]]] <- a
  }
  wrapped <- na >= 2 && coin(0.08)
  wcode <- NULL
  if (wrapped) {   # Asset W als Fonds-Wrapper über A und B (statt A und B)
    wcode <- wrap_code(pick(c(0, 0.5, 1.5)), pick(c(0, 10)), coin(0.4))
    rest <- st[setdiff(names(st), c("A", "B"))]
    for (x in names(rest)) rest[[x]]$share <- 0.3
    st <- c(list(W = list(asset_class = pick(c("etf", "certificate")), trading = "bnh", share = if (length(rest)) 0.7 else 1,
                          spread = pick(list(NULL, 0.1)), wrapper = TRUE)), rest)
  }
  if (n > 10 && coin(0.12)) {   # Lücken (fehlende Kalendertage)
    keep <- sort(unique(c(1, n, sample(2:(n - 1), floor((n - 2) * runif(1, 0.4, 0.95))))))
    d <- d[keep, , drop = FALSE]; rownames(d) <- NULL
  }
  nr <- nrow(d)
  # Bausteine (flach, dann blocks_from_flat)
  a <- list(start_value = pick(c(1e4, 1e4, 500, 25000, 1e6)))
  plain <- coin(0.45)   # ohne Steuer und Splits
  if (coin(0.5)) {
    a$dca_mode <- TRUE; a$dca_value <- pick(c(50, 200, 1000)); a$dca_unit <- pick(c("month", "month", "quarter", "year"))
    a$dca_span <- pick(c(1, 1, 2, 3))
    if (coin(0.4)) a$dca_days <- pick(list(1, 15, 28, 31, c(1, 15)))
    if (coin(0.2)) a$dca_anchor <- pick(c("start", "end"))
    if (coin(0.15)) a$dca_skip <- TRUE
    if (coin(0.1)) a$dca_start <- format(start + sample(0:max(1, n %/% 2), 1))
    if (coin(0.2)) a$dca_fee <- pick(list(1, list(percent = 0.5), list(fixed = 1, percent = 0.25, min = 2, max = 10)))
  }
  if (coin(0.55)) {
    a$balance_mode <- TRUE; a$balance_unit <- pick(c("month", "quarter", "year"))
    if (coin(0.3)) a$balance_span <- pick(c(1, 2))
    if (coin(0.25)) a$balance_days <- pick(list(1, 10, 31))
    if (coin(0.4)) { a$balance_thresh <- pick(c(1, 5, 20)); a$balance_thresh_type <- pick(c("absolute", "relative")) }
    if (coin(0.2)) a$balance_dca <- TRUE
  }
  if (nr > 3 && coin(0.15)) {
    d$ev <- runif(nr) < pick(c(0.02, 0.1)); a$event_col <- "ev"; a$event_mode <- pick(c("additional", "replace"))
    if (coin(0.4)) {
      for (x in names(st)) d[[paste0("w", x)]] <- round(runif(nr), 3)
      a$event_weight <- setNames(as.list(paste0("w", names(st))), names(st))
    }
  }
  if (coin(0.25)) a$order_fee <- pick(list(1, 4.95, list(percent = 0.25, min = 1), list(fixed = 2, percent = 0.1, max = 20)))
  if (!plain) {
    if (coin(0.2)) { a$split_mode <- TRUE; a$split_thresh <- pick(list(c(20, 400), c(50, 150), c(1, 1000))) }
    if (coin(0.7)) {
      a$tax_mode <- "person"
      if (coin(0.3)) a$church_tax <- pick(c(8, 9)) else if (coin(0.2)) a$tax_rate <- pick(c(25, 26.375))
      if (coin(0.4)) a$base_rate <- pick(c(0, 1.5, 2.55))
      if (coin(0.2)) a$sparer_pauschbetrag <- pick(c(0, 801, 1000))
      tariff <- coin(0.2)
      if (tariff) a$taxable_income <- pick(c(15000, 40000, 90000))
      else if (coin(0.2)) { a$use_guenstigerpruefung <- TRUE; a$marginal_tax_rate <- pick(c(14, 25, 42)) }
      if (coin(0.15)) { a$harvest_mode <- TRUE; if (coin(0.5)) a$harvest_day <- pick(c("11-15", "12-01")) }
    }
  }
  if (coin(0.3)) a$details <- TRUE
  if (coin(0.2)) a$fractions <- FALSE
  if (coin(0.3)) a$liquidate <- TRUE
  if (coin(0.1)) a$risk_free <- pick(c(1, 2.5))
  bl <- blocks_from_flat(a)
  r <- sim_code("d", "s", bl, "r"); py <- sim_code("d", "s", bl, "py"); jl <- sim_code("d", "s", bl, "jl")
  if (wrapped) {
    sc <- strat_code(st)
    r <- paste(wcode$r, sc$r, r, sep = "\n")
    py <- paste(wcode$py, sc$py, paste0("result = ", py), sep = "\n")
    jl <- paste(wcode$jl, sc$jl, paste0("result = ", jl), sep = "\n")
    fuzz_case(id, r = r, py = py, jl = jl, inputs = list(d = d))
  } else {
    s <- do.call(create_strategy, lapply(st, function(x) do.call(asset_config, x[!vapply(x, is.null, NA)])))
    fuzz_case(id, r = r, py = paste0("result = ", py), jl = paste0("result = ", jl), inputs = list(d = d, s = s))
  }
}
# Zusatzfälle (E17 1c): Split-Abbruch. Am ersten Tag splittet die Kursreihe ohne Bestand (1e300 über der oberen
# Schwelle), der zweite Kurs unterläuft dabei auf 0; am zweiten Tag liegt 0 über der (negativen) oberen Schwelle,
# der Split des gekauften Bestands hat ratio = 0: "perform_asset_split: ratio muss > 0 sein".
xcase <- list(
  list(d = data.frame(date = as.Date("2020-01-01") + 0:1, A = c(1e300, 1e-30)), sh = c(A = 1),
       a = list(start_value = 1e4, split_mode = TRUE, split_thresh = c(-50, -10), details = TRUE)),
  list(d = data.frame(date = as.Date("2015-12-30") + 0:1, A = c(1e300, 1e-30), B = c(50, 51)), sh = c(A = 0.5, B = 0.5),
       a = list(start_value = 25000, split_mode = TRUE, split_thresh = c(-50, -10), tax_mode = "person")),
  list(d = data.frame(date = as.Date("2021-06-01") + 0:1, A = c(1e300, 1e-30)), sh = c(A = 1),
       a = list(start_value = 1e4, split_mode = TRUE, split_thresh = c(-50, -10), fractions = FALSE, liquidate = TRUE,
                details = TRUE)))
for (k in seq_along(xcase)) {
  x <- xcase[[k]]
  s <- do.call(create_strategy, lapply(x$sh, function(w) asset_config("etf", "bnh", w)))
  bl <- blocks_from_flat(x$a)
  fuzz_case(sprintf("x%05d", k), r = sim_code("d", "s", bl, "r"), py = paste0("result = ", sim_code("d", "s", bl, "py")),
            jl = paste0("result = ", sim_code("d", "s", bl, "jl")), inputs = list(d = x$d, s = s))
}
ref_done(); ref_schreiben()
