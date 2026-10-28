# Referenzfälle für simulation() mit den Argumenten und Ergebniselementen von 0.5.0
# (Gebühren, Kirchensteuer, Freibetrag nutzen, Einkommensteuertarif, Günstigerprüfung,
# Fondsmodus, Sparplan, Rebalancing-Bänder, Splits, später startende Assets,
# details = TRUE, summary()) mit dem vollständigen Ergebnis als Baum sowie
# Warn- und Fehlerpfade aus den testthat-Dateien der Engine.
# Ergänzt golden/cases und golden/extra (dort ohne tariff_years/next_year/open_tax_debt).
#
# Aufruf aus der Repo-Wurzel:
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript golden/modules/gen_engine.R
source("golden/modules/ref_tools.R")
# Fälle als flache Argumentlisten beschrieben (wie bis 6.2); simulation() bekommt die nach Anhang C
# übersetzten Bausteine (golden/tools/blocks_from_flat.R, Etappe 6.3). BK() gibt einen Baustein direkt an.
source("golden/tools/blocks_from_flat.R")
BK <- function(ctor, ...) flatblock(ctor, list(...))
ref_init("engine")

# ── Argumente einmal angeben, Code für R, Python und Julia erzeugen ───────────
V <- function(x) structure(x, class = "refvar")          # Verweis auf eine Eingabevariable
.num1 <- function(x, L) {
  if (is.nan(x)) return(switch(L, r = "NaN", py = "float('nan')", jl = "NaN"))
  if (is.infinite(x)) return(switch(L, r = if (x > 0) "Inf" else "-Inf", py = if (x > 0) "math.inf" else "-math.inf",
                                    jl = if (x > 0) "Inf" else "-Inf"))
  s <- format(x, digits = 15, scientific = FALSE)
  s
}
.str1 <- function(x, L) if (L == "jl") sprintf('"%s"', x) else sprintf("'%s'", x)
em <- function(v, L) {
  if (inherits(v, "refvar")) return(unclass(v))
  if (inherits(v, "flatblock")) {               # Baustein: Konstruktoraufruf
    a <- v$args; nm <- if (is.null(names(a))) rep("", length(a)) else names(a); pos <- !nzchar(nm)   # Positionsargumente zuerst
    val <- vapply(a, em, "", L)
    kw <- switch(L, py = sprintf("%s=%s", nm[!pos], val[!pos]), sprintf("%s = %s", nm[!pos], val[!pos]))
    if (L == "jl") {
      inner <- paste(val[pos], collapse = ", ")
      if (length(kw)) inner <- paste0(inner, "; ", paste(kw, collapse = ", "))
      return(sprintf("SL.%s(%s)", v$ctor, inner))
    }
    return(sprintf("%s%s(%s)", if (L == "py") "simlev." else "", v$ctor, paste(c(val[pos], kw), collapse = ", ")))
  }
  if (is.null(v)) return(switch(L, r = "NULL", py = "None", jl = "nothing"))
  if (is.list(v)) {
    nm <- names(v)
    if (is.null(nm)) return(switch(L, r = sprintf("list(%s)", paste(vapply(v, em, "", L), collapse = ", ")),
                                   sprintf("[%s]", paste(vapply(v, em, "", L), collapse = ", "))))
    parts <- vapply(seq_along(v), function(i) switch(L, r = sprintf("%s = %s", nm[i], em(v[[i]], L)),
                                                     py = sprintf("'%s': %s", nm[i], em(v[[i]], L)),
                                                     jl = sprintf("%s = %s", nm[i], em(v[[i]], L))), "")
    return(switch(L, r = sprintf("list(%s)", paste(parts, collapse = ", ")),
                  py = sprintf("{%s}", paste(parts, collapse = ", ")),
                  jl = sprintf("(%s%s)", paste(parts, collapse = ", "), if (length(v) == 1) "," else "")))
  }
  el <- if (is.logical(v)) switch(L, r = ifelse(v, "TRUE", "FALSE"), py = ifelse(v, "True", "False"), jl = ifelse(v, "true", "false"))
        else if (is.character(v)) vapply(v, .str1, "", L) else vapply(v, .num1, "", L)
  el <- unname(el)
  if (!is.null(names(v))) {
    nm <- names(v)
    return(switch(L, r = sprintf("c(%s)", paste(sprintf("%s = %s", nm, el), collapse = ", ")),
                  py = sprintf("{%s}", paste(sprintf("'%s': %s", nm, el), collapse = ", ")),
                  jl = sprintf("[%s]", paste(sprintf('"%s" => %s', nm, el), collapse = ", "))))
  }
  if (length(v) == 1) return(el)
  switch(L, r = sprintf("c(%s)", paste(el, collapse = ", ")), sprintf("[%s]", paste(el, collapse = ", ")))
}
.args <- function(a, L) {
  if (!length(a)) return("")
  nm <- names(a)
  parts <- vapply(seq_along(a), function(i) switch(L, r = sprintf("%s = %s", nm[i], em(a[[i]], L)),
                                                   py = sprintf("%s=%s", nm[i], em(a[[i]], L)),
                                                   jl = sprintf("%s = %s", nm[i], em(a[[i]], L))), "")
  paste0(if (L == "jl") "; " else ", ", paste(parts, collapse = ", "))
}
sim_code <- function(d, s, a, L) switch(L,
  r = sprintf("simulation(%s, %s%s)", d, s, .args(a, "r")),
  py = sprintf("simlev.simulation(%s, %s%s)", d, s, .args(a, "py")),
  jl = sprintf("SL.simulation(%s, %s%s)", d, s, .args(a, "jl")))

# SIM: ganzes Ergebnis; part = Element (z. B. "tax_report"); wrap = "summary"
SIM <- function(id, a = list(), d = "d2", s = "s2", extra = list(), part = NULL, wrap = NULL, note = NULL,
                pre = NULL) {
  bn <- intersect(names(a), c("costs", "dca", "rebalance", "splits", "tax", "funds"))   # schon Bausteine (BK)
  a <- c(blocks_from_flat(a[setdiff(names(a), bn)]), a[bn])
  g <- function(x) if (!is.null(extra[[x]])) extra[[x]] else get(x)
  inp <- c(setNames(list(g(d), g(s)), c(d, s)), extra[setdiff(names(extra), c(d, s))])
  r <- sim_code(d, s, a, "r"); py <- sim_code(d, s, a, "py"); jl <- sim_code(d, s, a, "jl")
  if (identical(wrap, "summary")) { r <- sprintf("summary(%s)", r); py <- sprintf("simlev.summary(%s)", py); jl <- sprintf("summary(%s)", jl) }
  if (!is.null(part)) {
    r <- sprintf("%s$%s", r, part)
    py <- sprintf("%s[%s]", py, paste(sprintf("'%s'", strsplit(part, "$", fixed = TRUE)[[1]]), collapse = "]["))
    jl <- sprintf("%s[%s]", jl, paste(sprintf('"%s"', strsplit(part, "$", fixed = TRUE)[[1]]), collapse = "]["))
  }
  if (!is.null(pre)) { r <- paste0(pre$r, "\n", r); py <- paste0(pre$py, "\n", "result = ", py); jl <- paste0(pre$jl, "\n", "result = ", jl) }
  else { py <- paste0("result = ", py); jl <- paste0("result = ", jl) }
  ref_case(id, r = r, py = py, jl = jl, inputs = inp, note = note)
}


# Tarifdatei in jeder Sprache in eine temporäre Datei `f` schreiben (Zeilen aus der Eingabe L)
PRE_TT <- list(
  r = "f <- tempfile(fileext = '.csv'); writeLines(L, f)",
  py = "import os, tempfile\nfd, f = tempfile.mkstemp(suffix='.csv'); os.close(fd)\nwith open(f, 'w', encoding='utf-8') as fh:\n    fh.write('\\n'.join(np.atleast_1d(L)) + '\\n')",
  jl = 'f = tempname() * ".csv"; write(f, join(L isa AbstractString ? [L] : L, "\\n") * "\\n")')
# tax_tariff(f) mit Pfad 'F' in Ergebnis und Fehlermeldung (Pfade unterscheiden sich je Sprache)
RT <- function(id, lines, note = NULL) {
  ref_case(id, note = note, inputs = list(L = lines),
    r = paste0(PRE_TT$r, "\nx <- tryCatch(tax_tariff(f), error = function(e) stop(gsub(f, 'F', conditionMessage(e), fixed = TRUE), call. = FALSE))\nx$file <- 'F'\nx"),
    py = paste0(PRE_TT$py, "\ntry:\n    x = simlev.tax_tariff(file=f)\nexcept Exception as e:\n    raise ValueError(str(e).replace(f, 'F')) from None\nx.file = 'F'\nresult = x"),
    jl = paste0(PRE_TT$jl, '\nx = try\n    SL.tax_tariff(f)\ncatch e\n    error(replace(e isa ErrorException ? e.msg : sprint(showerror, e), f => "F"))\nend\nx["file"] = "F"\nresult = x'))
}

# ── Daten (kurze Zeitreihen) ──────────────────────────────────────────────────
mk <- function(start, n, seed, k = 2, mu = 3e-4, sig = 0.012, s0 = 50) {
  set.seed(seed)
  d <- data.frame(date = seq.Date(as.Date(start), by = "day", length.out = n))
  for (j in seq_len(k)) d[[LETTERS[j]]] <- round(s0 * j * cumprod(1 + rnorm(n, mu * j, sig)), 4)
  d
}
days <- function(a, b) seq.Date(as.Date(a), as.Date(b), by = "day")
d2 <- mk("2020-09-01", 250, 1, mu = 5e-4)                    # 2 Assets, 01.09.2020 bis 08.05.2021
d1 <- mk("2019-11-20", 420, 2, k = 1, mu = 6e-4)             # 1 Asset, drei Kalenderjahre
dT <- mk("2020-01-01", 40, 3)                                # klein, für Warn- und Fehlerpfade
dT1 <- dT[, c("date", "A")]
dC <- data.frame(date = days("2020-01-01", "2021-02-03")); dC$A <- seq(100, 200, length.out = nrow(dC)); dC$B <- 100
dK <- dC; dK$A <- 100
d_one <- d2[1, ]
dS <- d2; dS$b <- (seq_len(nrow(dS)) %% 50) < 20; dS$s <- (seq_len(nrow(dS)) %% 50) >= 35
dsp <- data.frame(date = days("2020-06-01", "2021-01-31")); set.seed(5)
dsp$A <- round(40 * exp(cumsum(rnorm(nrow(dsp), 8e-3, 0.01))), 4); dsp$B <- round(100 * exp(cumsum(rnorm(nrow(dsp), -5e-3, 0.01))), 4)
# § 23 / § 20 mit Umschichtung am 01.07.2020 (aus test-engine-notes.R)
.p23 <- function(p2 = 150, end = "2021-03-31") {
  d <- days("2020-01-01", end)
  df <- data.frame(date = d, G = ifelse(d < as.Date("2020-06-01"), 100, p2), H = 50)
  df$ev <- d == as.Date("2020-07-01"); df$wG <- 0; df$wH <- 1; df
}
dP <- .p23(); dPL <- .p23(p2 = 80)
dG <- data.frame(date = days("2020-01-01", "2021-03-31")); dG$Z <- ifelse(dG$date < as.Date("2020-06-01"), 50, 70); dG$M <- 100
dG$ev <- dG$date == as.Date("2020-07-01"); dG$wZ <- 0; dG$wM <- 1
dR <- data.frame(date = days("2020-01-01", "2021-06-30")); dR$G <- ifelse(dR$date < as.Date("2020-06-01"), 100, 150)
dR$H <- ifelse(dR$date < as.Date("2020-10-01"), 50, 1); dR$ev <- dR$date == as.Date("2020-07-01"); dR$wG <- 0; dR$wH <- 1
# Verlusttopf: A fällt bis zur Umschichtung am 01.09.2020, B steigt
dL <- data.frame(date = days("2020-06-01", "2020-12-31")); nL <- nrow(dL)
dL$A <- round(100 * seq(1, 0.7, length.out = nL), 4); dL$B <- round(50 * seq(1, 1.6, length.out = nL), 4)
dL$ev <- dL$date == as.Date("2020-09-01"); dL$wA <- 0.2; dL$wB <- 0.8
# jüngeres Asset (NA am Anfang, wie series_align(range = "all"))
dN <- d2; dN$B[seq_len(120)] <- NA
# Ereignisse mit Gewichten
dE <- d2; dE$ev <- FALSE; dE$ev[c(40, 130, 200)] <- TRUE; dE$wA <- 0.3 + 0.4 * (seq_len(nrow(dE)) %% 2); dE$wB <- 1 - dE$wA
dE$wN <- -1

s2 <- create_strategy(A = asset_config("etf", "bnh", 0.6, 0.1, 30), B = asset_config("etf", "bnh", 0.4, 0.2, 0))
s1 <- create_strategy(A = asset_config("etf", "bnh", 1, 0.1, 30))
s1c <- create_strategy(A = asset_config("certificate", "bnh", 1, 0))
sp <- create_strategy(A = asset_config("etc", "bnh", 0.5, 0.1, 0, deliverable = TRUE), B = asset_config("certificate", "bnh", 0.5, 0.1))
sC <- create_strategy(A = asset_config("certificate", share = 1, spread = 0))
sC2 <- create_strategy(A = asset_config("etf", share = .5), B = asset_config("etf", share = .5))
ssig <- create_strategy(A = asset_config("etc", "signal", 0.5, 0.2, 0, deliverable = TRUE, signal_buy = "b", signal_sell = "s"),
                        B = asset_config("etf", "bnh", 0.5, 0.1, 30))
sP <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                      H = asset_config("certificate", "bnh", share = 0.5, spread = 0))
sG <- create_strategy(Z = asset_config("certificate", "bnh", share = 0.5, spread = 0),
                      M = asset_config("certificate", "bnh", share = 0.5, spread = 0))
sL <- create_strategy(A = asset_config("etf", "bnh", 0.5, 0, 0), B = asset_config("certificate", "bnh", 0.5, 0))
sLate <- create_strategy(A = asset_config("etf", "bnh", 0.6, 0.1, 30), B = asset_config("etc", "bnh", 0.4, 0, start = "2020-11-02"))
sLate2 <- create_strategy(A = asset_config("etf", "bnh", 0.6, 0, start = "2020-10-01"), B = asset_config("etf", "bnh", 0.4, 0, start = "2020-11-02"))
sLate3 <- create_strategy(A = asset_config("etf", "bnh", 0.6, 0, 0), B = asset_config("etf", "bnh", 0.4, 0, start = "2021-05-08"))
sLate4 <- create_strategy(A = asset_config("etf", "bnh", 0.6, 0, 0), B = asset_config("etf", "bnh", 0.4, 0, start = "2021-06-01"))
sN <- create_strategy(A = asset_config("etf", share = .7, spread = 0), B = asset_config("etc", share = .3, spread = 0))
EV_P <- list(event_col = "ev", event_mode = "replace", event_weight = c(G = "wG", H = "wH"))
EV_G <- list(event_col = "ev", event_mode = "replace", event_weight = c(Z = "wZ", M = "wM"))
EV_L <- list(event_col = "ev", event_mode = "replace", event_weight = c(A = "wA", B = "wB"))
P <- function(...) c(list(start_value = 1e4, tax_mode = "person"), list(...))

# ── Ordergebühren (order_fee, dca_fee) ────────────────────────────────────────
SIM("fee01", list(order_fee = 5))
SIM("fee02", list(order_fee = list(fixed = 1, percent = 0.25, min = 2, max = 20), balance_mode = TRUE, tax_mode = "person"))
SIM("fee03", list(order_fee = 10, dca_fee = 1, dca_mode = TRUE, dca_value = 200, dca_span = 1, balance_mode = TRUE))
SIM("fee04", list(order_fee = 10, dca_fee = 0, dca_mode = TRUE, dca_value = 100, dca_span = 1, fractions = FALSE,
                  start_value = 50000, tax_mode = "person", liquidate = TRUE))
SIM("fee05", list(order_fee = list(percent = 0.5), tax_mode = "funds", liquidate = TRUE, balance_mode = TRUE, details = TRUE))
SIM("fee06", list(order_fee = list(percent = 0.25), dca_fee = 0, dca_mode = TRUE, dca_value = 100, dca_span = 1,
                  dca_days = 2, start_value = 50000), d = "d1", s = "s1", note = "Startkapital mit order_fee, Sparrate mit dca_fee")
SIM("fee07", list(order_fee = list(percent = 0.25), dca_fee = 0, dca_mode = TRUE, dca_value = 100, dca_span = 1,
                  start_value = 50000, balance_mode = TRUE, balance_span = 12), note = "erster Tag Sparplantag: zwei Orders")
SIM("fee08", list(dca_fee = list(percent = 1.5), dca_mode = TRUE, dca_value = 250, dca_span = 1), note = "nur dca_fee")
SIM("fee09", list(order_fee = list(fixed = 0, percent = 0.2, min = 5), details = TRUE), d = "dS", s = "ssig")
SIM("fee10", list(order_fee = 0))
SIM("fee11", list(order_fee = list(fixed = 0)))
SIM("fee12", list(order_fee = 4.95, tax_mode = "person", base_rate = 2.55, fractions = FALSE, details = TRUE), d = "d1", s = "s1",
    note = "Zwangsverkauf für die Vorabpauschale mit Gebühr")
SIM("fee13", list(order_fee = list(fixed = 1.5, percent = 0.25, min = 3, max = 30), balance_mode = TRUE,
                  balance_thresh = 10, balance_thresh_type = "relative", tax_mode = "person", liquidate = TRUE), d = "d2", s = "sLate")
SIM("fee14", list(order_fee = 2, split_mode = TRUE, split_thresh = c(60, 120), fractions = FALSE, tax_mode = "person"), d = "dsp")
SIM("fee15", list(start_value = 100, order_fee = 60, liquidate = TRUE), d = "dK", s = "sC", note = "Warnung: nicht verkauft")
SIM("fee16", list(order_fee = list(fix = 5)), d = "dT")
SIM("fee17", list(order_fee = -1), d = "dT")
SIM("fee18", list(order_fee = list(min = 10, max = 5)), d = "dT")
SIM("fee19", list(order_fee = "5"), d = "dT")
SIM("fee20", list(dca_fee = list(foo = 1), dca_mode = TRUE, dca_value = 10, dca_span = 1), d = "dT")
SIM("fee21", list(order_fee = 3, dca_mode = TRUE, dca_value = 100, dca_span = 1), wrap = "summary")
SIM("fee22", P(order_fee = 1, liquidate = TRUE, marginal_tax_rate = 30), d = "dP", s = "sP", extra = list(), note = "§ 23-Steuer mit Gebühr")
SIM("fee23", c(P(order_fee = list(fixed = 2, percent = 0.1), liquidate = TRUE), EV_G), d = "dG", s = "sG")

# ── Kirchensteuer (church_tax) ────────────────────────────────────────────────
SIM("ch01", list(tax_mode = "person", church_tax = 9, balance_mode = TRUE, liquidate = TRUE))
SIM("ch02", list(tax_mode = "person", church_tax = 8, tax_rate = 25, liquidate = TRUE))
SIM("ch03", list(church_tax = 0.09), d = "dC", s = "sC")
SIM("ch04", list(church_tax = 12), d = "dT")
SIM("ch05", P(church_tax = -9), d = "dT")
SIM("ch06", P(church_tax = "9"), d = "dT")
SIM("ch07", list(church_tax = 100), d = "dC", s = "sC")
SIM("ch08", list(tax_mode = "person", church_tax = 9, marginal_tax_rate = 35, liquidate = TRUE, details = TRUE), s = "sp")
SIM("ch09", list(tax_mode = "person", church_tax = 8, use_guenstigerpruefung = TRUE, marginal_tax_rate = 14,
                 include_soli_on_income_tax = TRUE, details = TRUE))
SIM("ch10", c(P(church_tax = 9, taxable_income = 74000, details = TRUE), EV_P), d = "dP", s = "sP")
SIM("ch11", c(P(church_tax = 8, taxable_income = 20000, use_guenstigerpruefung = TRUE, details = TRUE), EV_G), d = "dG", s = "sG")
SIM("ch12", list(tax_mode = "funds", church_tax = 9, liquidate = TRUE))
SIM("ch13", list(church_tax = 9, liquidate = TRUE))
SIM("ch14", c(P(church_tax = 9, marginal_tax_rate = 42, liquidate = TRUE), EV_P), d = "dP", s = "sP")
SIM("ch15", P(church_tax = c(8, 9)), d = "dT")

# ── Freibetrag nutzen (harvest_mode, harvest_day, harvest_loss_pot) ─────────────
SIM("hv01", list(tax_mode = "person", harvest_mode = TRUE), d = "d1", s = "s1")
SIM("hv02", list(tax_mode = "person", harvest_mode = TRUE, harvest_day = "11-30", harvest_loss_pot = FALSE, base_rate = 2,
                 details = TRUE, order_fee = 1), d = "d1", s = "s1")
SIM("hv03", list(harvest_mode = TRUE), d = "dC", s = "sC")
SIM("hv04", list(tax_mode = "person", harvest_mode = TRUE, harvest_day = "12-30"))
SIM("hv05", list(tax_mode = "person", harvest_mode = TRUE, fractions = FALSE, start_value = 30000, dca_mode = TRUE,
                 dca_value = 300, dca_span = 1), d = "d1", s = "s1")
SIM("hv06", list(tax_mode = "person", harvest_mode = TRUE, harvest_day = "1231"), d = "dT")
SIM("hv07", list(tax_mode = "person", harvest_mode = TRUE, harvest_day = "12-31"), d = "dT")
SIM("hv08", list(tax_mode = "person", harvest_mode = TRUE, harvest_day = "06-30", details = TRUE), s = "sp")
SIM("hv09", c(P(harvest_mode = TRUE, details = TRUE), EV_L), d = "dL", s = "sL", note = "Verlusttopf wird mitgenutzt")
SIM("hv10", c(P(harvest_mode = TRUE, harvest_loss_pot = FALSE, details = TRUE), EV_L), d = "dL", s = "sL")
SIM("hv11", c(P(harvest_mode = TRUE, church_tax = 9, taxable_income = 45000, liquidate = TRUE), EV_L), d = "dL", s = "sL")
SIM("hv12", list(tax_mode = "person", harvest_mode = TRUE, sparer_pauschbetrag = 0), d = "d1", s = "s1")
SIM("hv13", list(tax_mode = "person", harvest_mode = TRUE, use_sparer_pauschbetrag = FALSE), d = "d1", s = "s1")
SIM("hv14", list(tax_mode = "person", harvest_mode = TRUE, order_fee = list(fixed = 1, percent = 0.1), balance_mode = TRUE), wrap = "summary")
SIM("hv15", list(tax_mode = "funds", harvest_mode = TRUE), d = "dT")
SIM("hv16", list(tax_mode = "person", harvest_mode = TRUE, start_value = 2e5), d = "d1", s = "s1c")

# ── Einkommensteuertarif (taxable_income, tax_tariff) ──────────────────────────
ti_vec <- c("2020" = 50000, "2021" = 52000)
ti_vec3 <- c("2019" = 30000, "2020" = 52000, "2021" = 80000)
SIM("ti01", P(taxable_income = 50000, liquidate = TRUE), s = "sp")
SIM("ti02", P(taxable_income = V("ti"), church_tax = 9, liquidate = TRUE, details = TRUE), s = "sp", extra = list(ti = ti_vec))
SIM("ti03", P(taxable_income = V("ti"), use_guenstigerpruefung = TRUE, liquidate = TRUE, details = TRUE), d = "d1", s = "s1c",
    extra = list(ti = data.frame(year = 2019:2021, taxable_income = c(9000, 15000, 30000))))
SIM("ti04", P(taxable_income = 8000, use_guenstigerpruefung = TRUE, base_rate = 2.5), d = "d1", s = "s1")
SIM("ti05", c(P(taxable_income = V("ti")), EV_P), d = "dP", s = "sP", extra = list(ti = data.frame(Jahr = 2020:2021, Betrag = c(74000, 1))))
SIM("ti06", c(P(taxable_income = V("ti")), EV_P), d = "dP", s = "sP", extra = list(ti = data.frame(yr = 2020:2021, val = c(74000, 300000))))
SIM("ti07", P(taxable_income = V("ti")), d = "dT", extra = list(ti = data.frame(a = 2020, b = 1, c = 2)))
SIM("ti08", P(taxable_income = V("ti")), d = "dT", extra = list(ti = data.frame(year = 2020, taxable_income = "x")))
SIM("ti09", c(P(taxable_income = V("ti")), EV_P), d = "dP", s = "sP", extra = list(ti = c("2020" = 74000)))
SIM("ti10", P(taxable_income = c(1, 2)), d = "dT")
SIM("ti11", P(taxable_income = V("ti")), d = "dT", extra = list(ti = c("2020" = 1, "x" = 2)))
SIM("ti12", P(taxable_income = V("na")), d = "dT", extra = list(na = NA_real_))
SIM("ti13", P(taxable_income = NaN), d = "dT")
SIM("ti14", P(taxable_income = "50000"), d = "dT")
SIM("ti15", P(taxable_income = V("ti")), d = "dT", extra = list(ti = c("2020" = 1, "2020" = 2)))
SIM("ti16", P(taxable_income = 50000, marginal_tax_rate = 42, include_soli_on_income_tax = TRUE), d = "dT")
SIM("ti17", list(taxable_income = 50000), d = "dT")
SIM("ti18", P(tax_tariff = V("tt")), d = "dT", pre = list(r = "tt <- tax_tariff()", py = "tt = simlev.tax_tariff()", jl = "tt = SL.tax_tariff()"))
SIM("ti19", list(tax_tariff = "x.csv"), d = "dT")
SIM("ti20", P(taxable_income = 50000, tax_tariff = 42), d = "dT")
SIM("ti21", P(taxable_income = 50000, tax_tariff = "/nonexistent/steuertarif.csv"), d = "dT")
TT_OK <- c("# Geltung: Testtarif", "art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0",
           "zone,10001,10000,1,0,0.2,0", "soli,20350,,,5.5,11.9,")
SIM("ti22", c(P(taxable_income = 50000, tax_tariff = V("f")), EV_P), d = "dP", s = "sP", extra = list(L = TT_OK), pre = PRE_TT,
    note = "eigene Tarifdatei")
SIM("ti23", c(P(taxable_income = 50000, tax_tariff = V("tt"), church_tax = 8), EV_P), d = "dP", s = "sP", extra = list(L = TT_OK),
    pre = list(r = paste0(PRE_TT$r, "\ntt <- tax_tariff(f)"), py = paste0(PRE_TT$py, "\ntt = simlev.tax_tariff(file=f)"),
               jl = paste0(PRE_TT$jl, "\ntt = SL.tax_tariff(f)")), note = "eigenes Tarifobjekt")
SIM("ti24", P(taxable_income = 300000, church_tax = 8, liquidate = TRUE, details = TRUE), s = "sp")
SIM("ti25", P(taxable_income = V("ti"), base_rate = 2.55, details = TRUE), d = "d1", s = "s1", extra = list(ti = ti_vec3))
SIM("ti26", c(P(taxable_income = 0, use_guenstigerpruefung = TRUE, details = TRUE), EV_G), d = "dG", s = "sG")
SIM("ti27", c(P(taxable_income = -5000, liquidate = TRUE), EV_P), d = "dP", s = "sP")
SIM("ti28", P(taxable_income = 60000, church_tax = 9), wrap = "summary", s = "sp")
SIM("ti29", c(P(taxable_income = 74000, harvest_mode = TRUE, details = TRUE), EV_L), d = "dL", s = "sL")
SIM("ti30", c(P(taxable_income = 74000, marginal_tax_rate = 20), EV_P), d = "dP", s = "sP")
SIM("ti31", c(P(taxable_income = 50000, liquidate = TRUE, church_tax = 9, details = TRUE), EV_P), d = "dPL", s = "sP",
    note = "§ 23-Verlust mit Tarif")
SIM("ti32", c(P(taxable_income = 12000, use_guenstigerpruefung = TRUE, church_tax = 9, details = TRUE), EV_G), d = "dG", s = "sG")
SIM("ti33", P(taxable_income = 50000, tax_tariff = V("f")), d = "dT", extra = list(L = sub("0.2,0$", "zwei,0", TT_OK)), pre = PRE_TT,
    note = "Fehler beim Lesen der Tarifdatei aus simulation() (Pfad je Sprache verschieden, daher hier ohne Pfad)")

# ── tax_tariff() und print ────────────────────────────────────────────────
ref_case("rt01", r = "x <- tax_tariff(); x$file <- 'F'; x", py = "x = simlev.tax_tariff(); x.file = 'F'; result = x",
         jl = 'x = SL.tax_tariff(); x["file"] = "F"; result = x')
RT("rt02", TT_OK)
ref_case("rt03", r = "tax_tariff('/nonexistent/gibt_es_nicht.csv')", py = "result = simlev.tax_tariff(file='/nonexistent/gibt_es_nicht.csv')",
         jl = 'result = SL.tax_tariff("/nonexistent/gibt_es_nicht.csv")')
RT("rt04", sub(",c$", ",x", TT_OK))
RT("rt05", sub("^zone,10001", "zonen,10001", TT_OK))
RT("rt06", sub("0.2,0$", "zwei,0", TT_OK))
RT("rt07", sub("^zone,0,", "zone,5,", TT_OK))
RT("rt08", c(TT_OK[1:3], "zone,0,0,1,0,0,0", TT_OK[5]))
RT("rt09", c(TT_OK, "soli,1,,,1,1,"))
RT("rt10", TT_OK[-5])
RT("rt11", sub("10000,1,0,0.2", "10000,0,0,0.2", TT_OK))
RT("rt12", sub("5.5,11.9", "155,11.9", TT_OK))
RT("rt13", sub("10001,10000,1", "10001,0,1", TT_OK), note = "Sprung an der Zonengrenze: Warnung")
TB <- c("art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0"); TS <- "soli,20350,,,5.5,11.9,"
RT("rt14", c(TB, "zone,10001,0,1,0,42,-420042", TS))
RT("rt15", c(TB, "zone,10001,0,1,0,-0.1,1000.1", TS))
RT("rt16", c(TB, "zone,10001,10000,10000,500,1000,0", TS))
RT("rt17", c(TB, "zone,10001,0,1,0,0.2,50000", TS))
RT("rt18", gsub(",", ";", TT_OK))
RT("rt19", sub("0.2,0$", "0,2,0", TT_OK))
ref_case("rt20", r = "tax_tariff(42)", py = "result = simlev.tax_tariff(file=42)", jl = "result = SL.tax_tariff(42)")
RT("rt21", c("art,ab,bezug,teiler,a,b,c", TS))
RT("rt22", c(TB, "zone,10001,10000,1,0,0.2,0", "soli,-5,,,5.5,11.9,"))
RT("rt23", c("# Kopf ohne Geltung", TB, "zone,10001,10000,1,0,0.25,0", "zone,50000.5,0,1,0,0.4,-7500.13", "soli,1e9,,,5.5,11.9,"))

# ── Günstigerprüfung ───────────────────────────────────────────────────────────
SIM("gp01", c(P(use_guenstigerpruefung = TRUE), EV_G), d = "dG", s = "sG")
SIM("gp02", c(P(use_guenstigerpruefung = TRUE, marginal_tax_rate = 14, details = TRUE), EV_G), d = "dG", s = "sG")
SIM("gp03", c(P(use_guenstigerpruefung = TRUE, marginal_tax_rate = 42), EV_G), d = "dG", s = "sG")
SIM("gp04", c(P(use_guenstigerpruefung = TRUE, marginal_tax_rate = 20, include_soli_on_income_tax = TRUE, soli_rate_income_tax = 5.5), EV_G),
    d = "dG", s = "sG")
SIM("gp05", list(tax_mode = "funds", use_guenstigerpruefung = TRUE, marginal_tax_rate = 14), d = "dT")
SIM("gp06", c(P(use_guenstigerpruefung = TRUE, marginal_tax_rate = 20, church_tax = 9, liquidate = TRUE), EV_G), d = "dG", s = "sG")
SIM("gp07", list(tax_mode = "person", use_guenstigerpruefung = TRUE, marginal_tax_rate = 24, base_rate = 2.55, liquidate = TRUE), d = "d1", s = "s1")

# ── Fondsmodus ────────────────────────────────────────────────────────────────
SIM("fu01", list(tax_mode = "funds", liquidate = TRUE, details = TRUE))
SIM("fu02", list(tax_mode = "funds", funds_fee = 1, bonus_fee = 10, liquidate = TRUE), d = "d1", s = "s1")
SIM("fu03", list(tax_mode = "funds", funds_fee = 0.5, order_fee = 2, balance_mode = TRUE, balance_unit = "quarter"))
SIM("fu04", list(tax_mode = "funds", funds_fee = 100, bonus_fee = 100), d = "dT")
SIM("fu05", list(tax_mode = "funds", funds_fee = -1), d = "dT")
SIM("fu06", list(tax_mode = "funds", funds_fee = V("na")), d = "dT", extra = list(na = NA_real_))
SIM("fu07", list(tax_mode = "funds", funds_fee = 150), d = "dT")
SIM("fu08", list(tax_mode = "funds", funds_fee = "1"), d = "dT")
SIM("fu09", list(tax_mode = "funds", funds_fee = NULL), d = "dT")
# funds_fee/bonus_fee außerhalb des Fondsmodus zusammen mit Argumenten, die später given[[...]] prüfen
# (bis 0.5.0-Entwurf: given überschrieben -> "subscript out of bounds")
SIM("fg01", list(funds_fee = 1, church_tax = 9), d = "dT")
SIM("fg02", list(tax_mode = "person", funds_fee = 1, bonus_fee = 10, church_tax = 8), d = "dT")
SIM("fg03", list(tax_mode = "person", bonus_fee = 5, taxable_income = 50000, marginal_tax_rate = 0.3), d = "dT")
SIM("fg04", list(tax_mode = "person", funds_fee = 0.5, tax_rate = 25, church_tax = 9), d = "dT")
SIM("fg05", list(tax_mode = "person", funds_fee = 0.5, taxable_income = 60000, include_soli_on_income_tax = FALSE), d = "dT")
SIM("fu10", list(tax_mode = "funds", bonus_fee = -20), d = "dT")
SIM("fu11", list(tax_mode = "funds", bonus_fee = 150), d = "dT")
SIM("fu12", list(funds_fee = 0.5), d = "dT")
SIM("fu13", list(tax_mode = "person", funds_fee = 1, bonus_fee = 0), d = "dT")
SIM("fu14", list(tax_mode = "funds", dca_mode = TRUE, dca_value = 100, dca_span = 1, funds_fee = 2, bonus_fee = 20), d = "d1", s = "s1")
SIM("fu15", list(funds_fee = V("na")), d = "dT", extra = list(na = NA_real_), note = "ohne Fondsmodus ohne Wirkung")
SIM("fu16", list(tax_mode = "funds", funds_fee = 1), wrap = "summary")

# ── Sparplan (dca_*) ──────────────────────────────────────────────────────────
SIM("dc01", list(dca_mode = TRUE, dca_value = 100, dca_span = 1))
SIM("dc02", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 31, dca_anchor = "end"), d = "d1", s = "s1")
SIM("dc03", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = c(1, 15), dca_anchor = "end"))
SIM("dc04", list(dca_mode = TRUE, dca_value = 500, dca_span = 1, dca_unit = "quarter", dca_anchor = "end", tax_mode = "person"), d = "d1", s = "s1")
SIM("dc05", list(dca_mode = TRUE, dca_value = 1000, dca_span = 1, dca_unit = "year", dca_anchor = "end"), d = "d1", s = "s1")
SIM("dc06", list(dca_mode = TRUE, dca_value = 100, dca_span = 2, dca_days = 15))
SIM("dc07", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_start = "2020-11-01", details = TRUE))
SIM("dc08", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_skip = TRUE, dca_days = 28, dca_anchor = "end"))
SIM("dc09", list(dca_mode = TRUE, dca_value = 300, dca_span = 1, balance_mode = TRUE, balance_dca = TRUE, details = TRUE))
SIM("dc10", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = c(15, 15)), d = "dT")
SIM("dc11", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 40), d = "dT")
SIM("dc12", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = 0), d = "dT")
SIM("dc13", list(dca_mode = TRUE, dca_value = c(100, 200), dca_span = 1), d = "dT")
SIM("dc14", list(dca_mode = TRUE, dca_value = "100", dca_span = 1), d = "dT")
SIM("dc15", list(dca_mode = TRUE, dca_value = -5, dca_span = 1), d = "dT")
SIM("dc16", list(dca_mode = TRUE, dca_value = Inf, dca_span = 1), d = "dT")
SIM("dc17", list(dca_mode = TRUE, dca_value = 100), d = "dT")
SIM("dc18", list(dca_mode = TRUE, dca_value = 100, dca_span = 1.5), d = "dT")
SIM("dc19", list(dca_mode = TRUE, dca_value = 100, dca_span = V("na")), d = "dT", extra = list(na = NA_real_))
SIM("dc20", list(dca_mode = TRUE, dca_value = 1, dca_span = 1, dca_start = "2025-01-01"), d = "dT")
SIM("dc21", list(dca_value = 100), d = "dT")
SIM("dc22", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = c(5, 5, 20)), d = "dT")
SIM("dc23", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_anchor = "mitte"), d = "dT")
SIM("dc24", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, tax_mode = "person", liquidate = TRUE), wrap = "summary")

# ── Rebalancing (absolute und relative Bänder) ─────────────────────────────────
SIM("rb01", list(balance_mode = TRUE, balance_thresh = 5))
SIM("rb02", list(balance_mode = TRUE, balance_thresh = 25, balance_thresh_type = "relative", details = TRUE))
SIM("rb03", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, balance_mode = TRUE, balance_thresh = 3,
                 balance_thresh_type = "relative", details = TRUE))
SIM("rb04", list(balance_mode = TRUE, balance_days = c(1, 1)), d = "dT")
SIM("rb05", list(balance_mode = TRUE, balance_thresh = 0.05), d = "dT")
SIM("rb06", list(balance_thresh = 5), d = "dT")
SIM("rb07", list(balance_mode = TRUE, balance_unit = "quarter", balance_anchor = "end", balance_thresh = 2, balance_thresh_type = "absolute"))
SIM("rb08", list(balance_mode = TRUE, balance_span = 2, balance_days = 10, tax_mode = "person"))
SIM("rb09", list(balance_mode = TRUE, balance_thresh = 5, balance_thresh_type = "prozent"), d = "dT")
SIM("rb10", list(balance_mode = TRUE, balance_days = 40), d = "dT")
SIM("rb11", list(balance_mode = TRUE, balance_thresh = 40, balance_thresh_type = "relative", balance_unit = "month", tax_mode = "person",
                 church_tax = 9, liquidate = TRUE), d = "dsp")

# ── Splits ─────────────────────────────────────────────────────────────────────
SIM("sp01", list(split_mode = TRUE, split_thresh = c(50, 200)), d = "dsp")
SIM("sp02", list(split_mode = TRUE, split_thresh = c(60, 120), fractions = FALSE, tax_mode = "person", details = TRUE), d = "dsp")
SIM("sp03", list(split_mode = TRUE, split_thresh = c(10, 60)), d = "dsp")
SIM("sp04", list(split_mode = TRUE, split_thresh = c(150, 400)), d = "dsp")
SIM("sp05", list(split_mode = TRUE, split_thresh = c(10, 60, 200)), d = "dT")
SIM("sp06", list(split_mode = FALSE, split_thresh = c(10, 60)), d = "dT")
SIM("sp07", list(split_mode = TRUE, split_thresh = c(80, 125), dca_mode = TRUE, dca_value = 200, dca_span = 1, balance_mode = TRUE), d = "dsp")

# ── später startende Assets ────────────────────────────────────────────────────
SIM("la01", list(balance_mode = TRUE, tax_mode = "person"), s = "sLate")
SIM("la02", list(balance_mode = TRUE, balance_unit = "year", details = TRUE), d = "dN", s = "sN", note = "NA am Anfang wie series_align(range = 'all')")
SIM("la03", list(start_value = 1e4), s = "sLate4")
SIM("la04", list(start_value = 1e4, balance_mode = TRUE, balance_unit = "quarter"), s = "sLate4")
SIM("la05", list(start_value = 1e4), s = "sLate3", note = "start am letzten Datentag")
SIM("la06", list(), s = "sLate2")
SIM("la07", list(dca_mode = TRUE, dca_value = 100, dca_span = 1, balance_mode = TRUE, order_fee = 1, details = TRUE), s = "sLate")
SIM("la08", list(dca_mode = TRUE, dca_value = 100, dca_span = 1), d = "dN", s = "sN", wrap = "summary")

# ── Ereignisse ─────────────────────────────────────────────────────────────────
SIM("ev01", list(event_col = "ev", event_weight = c(A = "wA", B = "wB"), tax_mode = "person", details = TRUE), d = "dE", s = "sC2")
SIM("ev02", list(event_col = "ev", event_weight = c(A = "wA"), event_mode = "replace"), d = "dE", s = "sC2")
SIM("ev03", list(event_col = "ev", event_weight = c(A = "wA", B = "xx")), d = "dE", s = "sC2")
SIM("ev04", list(event_col = "ev", event_weight = c("wA", "wA")), d = "dE", s = "sC2")
SIM("ev05", list(event_col = "ev", event_weight = c(A = "wN", B = "wN")), d = "dE", s = "sC2")
SIM("ev06", list(event_mode = "replace"), d = "dT")
SIM("ev07", list(event_col = "ev", balance_thresh = 5, order_fee = 1), d = "dE", s = "sC2")

# ── Steuerschuld, undefined_metrics (aus test-engine-notes.R) ──────────────────
SIM("um01", c(P(marginal_tax_rate = 42), EV_P), d = "dR", s = "sP", note = "negativer Endwert, offene Steuerschuld")
SIM("um02", c(P(marginal_tax_rate = 42, dca_mode = TRUE, dca_value = 1000, dca_span = 1, dca_start = "2021-03-01"), EV_P),
    d = "dR", s = "sP", note = "nonpositive_twr_index, no_recovery")
SIM("um03", c(P(marginal_tax_rate = 42, dca_mode = TRUE, dca_value = 1000, dca_span = 1, dca_days = 30, dca_start = "2021-06-01"), EV_P),
    d = "dR", s = "sP", note = "no_irr_solution")
SIM("um04", c(P(marginal_tax_rate = 42), EV_P), d = "dR", s = "sP", wrap = "summary")
SIM("um05", list(), d = "d_one")
SIM("um06", list(details = TRUE, liquidate = TRUE, tax_mode = "person"), d = "d_one")
SIM("um07", list(), d = "d_one", wrap = "summary")
SIM("um08", c(P(marginal_tax_rate = 42, details = TRUE, liquidate = TRUE), EV_P), d = "dR", s = "sP")
SIM("um09", c(P(taxable_income = 74000, details = TRUE), EV_P), d = "dR", s = "sP")

# ── Daten- und Argumentprüfungen ───────────────────────────────────────────────
dDup <- rbind(dT, dT[20, ]); dDup <- dDup[order(dDup$date), ]
d0 <- dT; d0$A[10] <- 0
dNA1 <- dT; dNA1$A[1] <- NA
dNA <- dT; dNA$A[10] <- NA
dChr <- dT; dChr$date <- as.character(dChr$date)
dFmt <- dT; dFmt$date <- format(dFmt$date, "%d.%m.%Y")
dRev <- dT[nrow(dT):1, ]; rownames(dRev) <- NULL
SIM("da01", list(), d = "dDup")
SIM("da02", list(), d = "d0")
SIM("da03", list(), d = "dNA1")
SIM("da04", list(), d = "dNA", note = "LOCF, filled")
SIM("da05", list(), d = "dChr", note = "Datum als Text")
SIM("da06", list(), d = "dFmt")
SIM("da07", list(), d = "dRev", note = "absteigend sortiert")
SIM("da08", list(), d = "dT", s = "sZ", extra = list(sZ = create_strategy(Z = asset_config("etf"))))
SIM("da10", list(), d = "dT", s = "sK", extra = list(sK = create_strategy(A = asset_config("etf", share = 1, start = as.Date("2020-01-15")))))
SIM("da11", list(spread = 5), d = "dT")
SIM("da12", list(tax_rate = 0.26375), d = "dT")
SIM("da13", list(tax_mode = "person"), d = "dT", s = "sp")
SIM("da14", list(rebalance = BK("rebalance_plan", unit = "nix")), d = "dT", note = "match.arg im Baustein (früher tax_mode = \"nix\")")
SIM("da15", list(fractions = "ja"), d = "dT")
SIM("da16", list(start_value = -5), d = "dT")
SIM("da17", list(base_rate = 0.02, tax_mode = "person"), d = "dT")
SIM("da18", list(risk_free = 0.01), d = "dT")
SIM("da19", list(tax_mode = "person", marginal_tax_rate = 60), d = "dT", s = "sp")
SIM("da20", list(tax_mode = "person", marginal_tax_rate = 0.3), d = "dT", s = "sp")
SIM("da21", list(tax_mode = "person", sparer_pauschbetrag = -1), d = "dT")
SIM("da23", list(tax_mode = "person", private_sale_threshold = 600, sparer_pauschbetrag = 801, marginal_tax_rate = 24,
                 liquidate = TRUE, details = TRUE), s = "sp")
SIM("da24", list(), d = "dT1", s = "s1", wrap = "summary")
# Attribut 'filled' nach Zeilenauswahl (R2-03) und doppelte Spaltennamen
set.seed(7); cal <- days("2019-10-01", "2020-03-31"); wd <- cal[!format(cal, "%u") %in% c("6", "7")]
us <- data.frame(date = wd, A = round(100 * exp(cumsum(rnorm(length(wd), 4e-4, 0.011))), 4))
ref_case("da25", inputs = list(us = us, s1 = s1),
         r = "al <- series_align(A = us)\nsimulation(al[al$date >= as.Date('2020-01-01'), ], s1)",
         py = "al = simlev.series_align(A=us)\nresult = simlev.simulation(al[al['date'] >= np.datetime64('2020-01-01')], s1)",
         jl = 'al = SL.series_align(A = us)\nresult = SL.simulation(SL.rows(al, al["date"] .>= Date(2020, 1, 1)), s1)')
ref_case("da26", inputs = list(dT = dT, s2 = s2), r = "simulation(cbind(dT, dT['A']), s2)",
         py = "result = simlev.simulation(pd.concat([dT, dT[['A']]], axis=1), s2)",
         jl = 'result = SL.simulation(SL.RFrame(vcat(names(dT), "A"), AbstractVector[[dT[k] for k in names(dT)]..., dT["A"]]), s2)')

# ── Asset-Konfiguration (Prüfungen aus test-blue-engine.R) ────────────────────
ref_case("cf01", r = "asset_config('etf', partial_exemption = 0.3)", py = "result = simlev.asset_config(asset_class='etf', partial_exemption=0.3)",
         jl = 'result = SL.asset_config("etf"; partial_exemption = 0.3)')
ref_case("cf02", r = "asset_config('etf', share = '0.5')", py = "result = simlev.asset_config(asset_class='etf', share='0.5')",
         jl = 'result = SL.asset_config("etf"; share = "0.5")')
ref_case("cf03", r = "asset_config('etf', start = 'kein Datum')", py = "result = simlev.asset_config(asset_class='etf', start='kein Datum')",
         jl = 'result = SL.asset_config("etf"; start = "kein Datum")')
ref_case("cf04", r = "asset_config('etc', 'bnh', 0.3, start = '2020-01-01', deliverable = TRUE)",
         py = "result = simlev.asset_config(asset_class='etc', trading='bnh', share=0.3, start='2020-01-01', deliverable=True)",
         jl = 'result = SL.asset_config("etc", "bnh", 0.3; start = "2020-01-01", deliverable = true)')

# ── Zufallsfälle: Kombinationen aller Argumente (kurze Reihen, auch mit Lücken) ──
pick <- function(x) x[[sample.int(length(x), 1)]]
TT_ALT <- c("# Geltung: Testtarif", "art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0", "zone,10001,10000,1,0,0.2,-0.2",
            "zone,40001,0,1,0,0.4,-8000.4", "soli,15000,,,5.5,11.9,")
for (k in 1:22) {
  set.seed(4711 + k)
  n <- pick(c(3, 60, 200, 200, 400))
  start <- as.Date("2014-01-01") + sample(0:2500, 1)
  na <- pick(1:3); nms <- c("A", "B", "C")[1:na]
  df <- data.frame(date = seq.Date(start, by = "day", length.out = n))
  for (nm in nms) df[[nm]] <- round(runif(1, 10, 300) * cumprod(pmax(1e-3, 1 + pick(c(1, 1, 2, 3)) *
                                      rnorm(n, rnorm(1, 3e-4, 5e-4), runif(1, 0.003, 0.03)))), 4)
  sh <- if (na == 1) 1 else { w <- round(runif(na), 2) + 0.05; w <- w / sum(w); w[na] <- 1 - sum(w[-na]); w }
  use_sig <- runif(1) < 0.3
  if (use_sig) { df$sb <- runif(n) < 0.3; df$ss <- runif(n) < 0.3 }
  st <- list()
  for (i in seq_along(nms)) {
    cl <- pick(c("etf", "etf", "certificate", "etc", "etn")); sig <- use_sig && i == 1
    st[[nms[i]]] <- asset_config(cl, if (sig) "signal" else "bnh", sh[i], pick(c(0, 0.05, 0.1, 0.3)),
                                 if (cl == "etf") pick(c(0, 15, 30)) else 0,
                                 deliverable = (cl %in% c("etc", "etn")) && runif(1) < 0.5,
                                 start = if (i > 1 && n > 10 && runif(1) < 0.25) format(start + sample(1:max(2, n %/% 2), 1)) else NULL,
                                 signal_buy = if (sig) "sb" else NULL, signal_sell = if (sig) "ss" else NULL)
  }
  st <- create_strategy(assets = st)
  if (n > 10 && runif(1) < 0.3) df <- df[sort(c(1, n, sample(2:(n - 1), floor((n - 2) * 0.7)))), ]
  a <- list(start_value = pick(c(1000, 10000, 123456.78, 5e5)))
  tm <- pick(c("none", "person", "person", "person", "funds")); a$tax_mode <- tm
  extra <- list(); pre <- NULL
  if (runif(1) < 0.5) a$liquidate <- TRUE
  if (runif(1) < 0.5) { a$dca_mode <- TRUE; a$dca_value <- pick(c(50, 250, 1000)); a$dca_span <- pick(1:3)
    a$dca_unit <- pick(c("month", "quarter", "year")); if (runif(1) < 0.4) a$dca_days <- pick(list(1, 15, c(1, 28), 31))
    if (runif(1) < 0.3) a$dca_anchor <- "end"; if (runif(1) < 0.3) a$balance_dca <- TRUE }
  if (runif(1) < 0.6) { a$balance_mode <- TRUE; a$balance_unit <- pick(c("month", "quarter", "year"))
    if (runif(1) < 0.4) a$balance_thresh <- pick(c(1, 5, 10)); if (runif(1) < 0.3) a$balance_thresh_type <- "relative" }
  if (runif(1) < 0.45) a$order_fee <- pick(list(1, 4.95, list(fixed = 1.5, percent = 0.25, min = 3, max = 30), list(percent = 0.1),
                                                list(fixed = 0, percent = 0.2, min = 5)))
  if (runif(1) < 0.3) a$dca_fee <- pick(list(0, 1.5, list(percent = 1.5)))
  if (runif(1) < 0.3) a$fractions <- FALSE
  if (runif(1) < 0.3) a$risk_free <- pick(c(0, 1.5, 4))
  if (tm == "person") {
    if (runif(1) < 0.6) a$base_rate <- pick(c(-0.5, 1, 2.55, 4))
    if (runif(1) < 0.4) a$church_tax <- pick(c(8, 9))
    if (runif(1) < 0.35) { a$harvest_mode <- TRUE; if (runif(1) < 0.5) a$harvest_day <- pick(c("11-01", "12-20", "06-30"))
      if (runif(1) < 0.3) a$harvest_loss_pot <- FALSE }
    if (runif(1) < 0.4) {
      ti <- pick(list(12000, 30000, 80000, 300000, "named", "df"))
      yrs <- seq(as.integer(format(min(df$date), "%Y")), as.integer(format(max(df$date), "%Y")))
      if (identical(ti, "named")) ti <- setNames(round(runif(length(yrs), 5000, 120000)), yrs)
      else if (identical(ti, "df")) ti <- data.frame(year = yrs, taxable_income = round(runif(length(yrs), 5000, 120000), 2))
      if (is.numeric(ti) && length(ti) == 1 && is.null(names(ti))) a$taxable_income <- ti
      else { extra$ti <- ti; a$taxable_income <- V("ti") }
      if (runif(1) < 0.2) { a$tax_tariff <- V("f"); extra$L <- TT_ALT; pre <- PRE_TT } }
    if (runif(1) < 0.4) a$marginal_tax_rate <- pick(c(14, 24, 42))
    if (runif(1) < 0.35) a$use_guenstigerpruefung <- TRUE
    if (runif(1) < 0.2) a$include_soli_on_income_tax <- TRUE
    if (runif(1) < 0.2) a$sparer_pauschbetrag <- pick(c(0, 801, 2000))
    if (runif(1) < 0.2) a$private_sale_threshold <- pick(c(0, 600))
  }
  if (tm == "funds" && runif(1) < 0.5) { a$funds_fee <- pick(c(0, 0.5, 2)); a$bonus_fee <- pick(c(0, 10, 20)) }
  if (runif(1) < 0.15) a$details <- TRUE
  if (runif(1) < 0.12) { bad <- pick(list(list(tax_rate = 0.26), list(church_tax = 0.08), list(church_tax = 12), list(balance_thresh = 0.05),
                                            list(order_fee = list(fix = 1)), list(harvest_day = "1231"),
                                            list(dca_days = c(1, 1, 15), dca_mode = TRUE, dca_value = 10, dca_span = 1),
                                            list(funds_fee = 1), list(taxable_income = c(1, 2)), list(spread = 0.1), list(marginal_tax_rate = 0.3),
                                            list(base_rate = 0.01), list(sparer_pauschbetrag = -1), list(fractions = 1),
                                            list(split_mode = TRUE, split_thresh = c(150, 400)), list(dca_value = 5), list(start_value = -5)))
    a[names(bad)] <- bad }
  dname <- sprintf("dz%02d", k); sname <- sprintf("sz%02d", k)
  assign(dname, df); assign(sname, st)
  SIM(sprintf("zz%02d", k), a, d = dname, s = sname, extra = extra, pre = pre)
}
# ── Bausteine (Etappe 6.3): Prüfungen, Zusammenspiel, Druck ────────────────────
BLK <- function(id, b, note = NULL, inputs = list())
  ref_case(id, r = em(b, "r"), py = paste0("result = ", em(b, "py")), jl = paste0("result = ", em(b, "jl")), note = note,
           inputs = inputs)
SIM("bk01", list(tax = BK("tax_profile"), funds = BK("funds_costs")), d = "dT", note = "Fondsmodus mit tax_profile() (Etappe 6.4)")
SIM("bk02", list(tax = BK("tax_profile", rate = 25, church_tax = 9)), d = "dT", note = "rate mit church_tax: Fehler")
SIM("bk03", list(tax = BK("tax_profile", rate = 26.375, church_tax = 8)), d = "dT", note = "auch der Standardwert ausdrücklich: Fehler")
SIM("bk04", list(tax = BK("tax_profile", income = 42)), d = "dT")
SIM("bk05", list(costs = 5), d = "dT")
SIM("bk06", list(dca = list(value = 100, span = 1)), d = "dT")
SIM("bk07", list(costs = NULL), d = "dT", note = "costs = NULL: keine Kosten")
SIM("bk08", list(tax = BK("tax_profile", base_rate = "br")), d = "dT", note = "Basiszins-Spalte fehlt")
SIM("bk09", list(tax = BK("tax_profile", guenstigerpruefung = TRUE)), d = "dT", note = "Günstigerprüfung ohne Grenzsteuersatz: Warnung")
SIM("bk10", list(tax = BK("tax_profile")), d = "dT", s = "sp", note = "§ 23 ohne Grenzsteuersatz: Warnung")
SIM("bk11", list(rebalance = BK("rebalance_plan", event_col = "ev", event_mode = "replace", event_weight = c(A = "wA", B = "wB"))),
    d = "dE", s = "sC2", note = "nur Ereignistage, am ersten Tag Kauf über das Rebalancing (skip = FALSE)")
SIM("bk12", list(rebalance = BK("rebalance_plan", event_col = "ev", event_mode = "replace", skip = TRUE,
                                event_weight = c(A = "wA", B = "wB")), details = TRUE),
    d = "dE", s = "sC2", note = "nur Ereignistage, am ersten Tag ohne Rebalancing (skip = TRUE)")
SIM("bk13", list(tax = BK("tax_profile", sparer_pauschbetrag = 0, base_rate = 2.55), details = TRUE), d = "d1", s = "s1",
    note = "sparer_pauschbetrag = 0 heißt ohne Pauschbetrag")
SIM("bk14", list(dca = BK("dca_plan", 100, 1, start = "2025-01-01")), d = "dT", note = "Beginn nach dem letzten Datentag")
SIM("bk15", list(rebalance = BK("rebalance_plan", start = "2025-01-01")), d = "dT")
SIM("bk16", list(tax = BK("tax_profile", income = BK("income_tariff", 50000)), funds = NULL), d = "dT", s = "sp")
SIM("bk17", list(fractions = 1), d = "dT")
SIM("bk18", list(tax = BK("tax_profile", income = BK("income_tariff", 50000)), funds = BK("funds_costs")), d = "dT",
    note = "Fondsmodus: income_tariff() wirkt nicht (Warnung)")
SIM("bk19", list(tax = BK("tax_profile", rate = 20), funds = BK("funds_costs", fee = 0.5), liquidate = TRUE),
    note = "Fondsmodus mit eigenem Steuersatz")
BLK("bk20", BK("dca_plan"), note = "value fehlt")
BLK("bk21", BK("dca_plan", value = 0, span = 1))
BLK("bk22", BK("dca_plan", value = 100, span = 2.5))
BLK("bk23", BK("dca_plan", value = 100, span = 1, days = c(5, 5)), note = "doppelte Tage: Warnung")
BLK("bk24", BK("dca_plan", value = 100, span = 1, days = 32))
BLK("bk25", BK("dca_plan", value = 100, span = 1, anchor = "mitte"))
BLK("bk26", BK("dca_plan", value = 100, span = 1, start = "kein Datum"))
BLK("bk27", BK("dca_plan", value = 100, span = 1, skip = 1))
BLK("bk28", BK("rebalance_plan", thresh = -1))
BLK("bk29", BK("rebalance_plan", thresh = 0.05), note = "Anteil statt Prozent: Warnung")
BLK("bk30", BK("rebalance_plan", event_mode = "replace"), note = "event_mode ohne event_col: Warnung")
BLK("bk31", BK("rebalance_plan", event_weight = c(A = "wA")), note = "event_weight ohne event_col: Warnung")
BLK("bk32", BK("rebalance_plan", thresh_type = "prozent"))
BLK("bk33", BK("rebalance_plan", event_col = 5))
BLK("bk34", BK("split_rule"), note = "thresh fehlt")
BLK("bk35", BK("split_rule", c(10, 60, 200)))
BLK("bk36", BK("split_rule", c(150, 400)), note = "100 nicht eingeschlossen: Warnung")
BLK("bk37", BK("tax_profile", rate = 0.26375), note = "Anteil statt Prozent: Warnung")
BLK("bk38", BK("tax_profile", rate = 150))
BLK("bk39", BK("tax_profile", church_tax = 12), note = "ungewöhnlich hoch: Warnung")
BLK("bk40", BK("tax_profile", church_tax = "9"))
BLK("bk41", BK("tax_profile", sparer_pauschbetrag = -1))
BLK("bk42", BK("tax_profile", private_sale_threshold = "1000"))
BLK("bk43", BK("tax_profile", base_rate = c(1, 2)))
BLK("bk44", BK("tax_profile", base_rate = 0.02), note = "Anteil statt Prozent: Warnung")
BLK("bk45", BK("tax_profile", guenstigerpruefung = "ja"))
BLK("bk46", BK("tax_profile", harvest = TRUE))
BLK("bk47", BK("income_rate"), note = "marginal_rate fehlt")
BLK("bk48", BK("income_rate", 60))
BLK("bk49", BK("income_rate", 0.42), note = "Anteil statt Prozent: Warnung")
BLK("bk50", BK("income_rate", 42, soli_rate = -1))
BLK("bk51", BK("income_tariff"), note = "taxable_income fehlt")
BLK("bk52", BK("income_tariff", "50000"))
BLK("bk53", BK("income_tariff", c(1, 2)))
BLK("bk54", BK("income_tariff", 50000, tariff = 42))
BLK("bk55", BK("harvest_rule", day = "12-31"))
BLK("bk56", BK("harvest_rule", loss_pot = "ja"))
BLK("bk57", BK("funds_costs", fee = 150))
BLK("bk58", BK("funds_costs", performance_fee = V("na")), inputs = list(na = NA_real_))
BLK("bk59", BK("sim_costs", order_fee = list(fix = 1)))
BLK("bk60", BK("sim_costs", dca_fee = -1))
# Druck und Inhalt der Bausteine
BLK("pr01", BK("sim_costs"))
BLK("pr02", BK("sim_costs", order_fee = list(fixed = 1.5, percent = 0.25, min = 3, max = 30), dca_fee = 0))
BLK("pr03", BK("sim_costs", order_fee = 4.95, dca_fee = list(percent = 1.5)))
BLK("pr04", BK("dca_plan", 200, 1))
BLK("pr05", BK("dca_plan", value = 123.45, span = 3, days = c(1, 15), unit = "quarter", anchor = "end", start = "2020-11-01",
               skip = TRUE, fill_deficits = TRUE))
BLK("pr06", BK("rebalance_plan"))
BLK("pr07", BK("rebalance_plan", span = 2, days = 10, unit = "year", thresh = 25, thresh_type = "relative", start = "2021-01-01"))
BLK("pr08", BK("rebalance_plan", event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wA", B = "wB"), thresh = 5))
BLK("pr09", BK("rebalance_plan", unit = "quarter", event_col = "ev"))
BLK("pr10", BK("split_rule", c(20, 400)))
BLK("pr11", BK("tax_profile"))
BLK("pr12", BK("tax_profile", church_tax = 9, sparer_pauschbetrag = 0, private_sale_threshold = 600, base_rate = "br",
               guenstigerpruefung = TRUE, income = BK("income_rate", 42, soli_rate = 5.5), harvest = BK("harvest_rule", day = "11-30", loss_pot = FALSE)))
BLK("pr13", BK("tax_profile", rate = 25, base_rate = 2.29, income = BK("income_tariff", 50000)))
BLK("pr14", BK("tax_profile", income = BK("income_tariff", V("ti"))), inputs = list(ti = c("2020" = 50000, "2021" = 52000)))
BLK("pr15", BK("income_rate", 24.5))
BLK("pr16", BK("income_tariff", 50000))
BLK("pr17", BK("harvest_rule"))
BLK("pr18", BK("funds_costs"))
BLK("pr19", BK("funds_costs", fee = 0.2, performance_fee = 0))
BLK("pr20", BK("income_tariff", V("ti")), note = "zvE als data.frame",
    inputs = list(ti = data.frame(year = 2020:2021, taxable_income = c(50000, 52000))))
ref_done()
