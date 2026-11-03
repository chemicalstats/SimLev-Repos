# tests/gleichlauf/erzeugen/engine.R – Bereich engine als Szenarien und Tabellen (seit 1.4.2; bis 1.4.1 110 Einzelfälle).
#   gleichlauf  Szenarien: je Szenario ein simulation()-Lauf; geprüft werden zugleich Ergebnis (ganzer Baum), Druck,
#               summary() samt Druck, details-Ausgabe und Warnungen. Feld note: "prüft: …"
#   fehler      je Funktion eine Tabelle "Eingabe -> erwartete Meldung" (jede Zeile ein eigener Aufruf)
#   ausgabe     Druck der Bausteine als Tabelle
# Herkunft der Erwartung: R. Aufruf (Repo-Wurzel): LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/gleichlauf/erzeugen/engine.R
# Ausgabe tests/{gleichlauf,fehler,ausgabe}/faelle/engine.jsonl.gz (Format und Umgebung: tests/gleichlauf/erzeugen/ref_tools.R).
source("tests/gleichlauf/erzeugen/ref_tools.R")
ref_bereich("engine")
source("tests/gleichlauf/erzeugen/blocks_from_flat.R")
BK <- function(ctor, ...) flatblock(ctor, list(...))
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

# simulation()-Aufruf in R, Python und Julia aus flachen Argumenten (Bausteine über blocks_from_flat bzw. BK);
# Ergebnis: Code (r, py, jl ohne Zuweisung) und Eingaben
simcode <- function(a = list(), d = "d2", s = "s2", extra = list()) {
  bn <- intersect(names(a), c("costs", "dca", "rebalance", "splits", "tax"))   # schon Bausteine (BK)
  a <- c(blocks_from_flat(a[setdiff(names(a), bn)]), a[bn])
  g <- function(x) if (!is.null(extra[[x]])) extra[[x]] else get(x)
  inp <- c(setNames(list(g(d), g(s)), c(d, s)), extra[setdiff(names(extra), c(d, s))])
  list(r = sim_code(d, s, a, "r"), py = sim_code(d, s, a, "py"), jl = sim_code(d, s, a, "jl"), inputs = inp)
}
.vor <- function(pre, L, x) if (is.null(pre)) x else paste0(pre[[L]], "\n", x)

# Szenario: ein simulation()-Lauf; Ergebnis, Druck, summary() und ihr Druck in einem Fall (Warnungen und
# details-Ausgabe prüft der Fall ohnehin). prueft: Zeile "prüft: …"
SZ <- function(id, prueft, a = list(), d = "d2", s = "s2", extra = list(), pre = NULL) {
  k <- simcode(a, d, s, extra)
  ref_case(id, note = paste("prüft:", prueft), inputs = k$inputs, print = FALSE,
    r = .vor(pre, "r", paste0("e <- ", k$r, "\nlist(ergebnis = e, druck = capture.output(print(e)), zusammenfassung = summary(e), ",
                             "druck_zusammenfassung = capture.output(print(summary(e))))")),
    py = .vor(pre, "py", paste0("e = ", k$py, "\nz = simlev.summary(e)\nresult = {'ergebnis': e, 'druck': str(e).split('\\n'), ",
                               "'zusammenfassung': z, 'druck_zusammenfassung': str(z).split('\\n')}")),
    jl = .vor(pre, "jl", paste0("e = ", k$jl, "\nz = summary(e)\n_dr(x) = split(chomp(sprint(show, MIME\"text/plain\"(), x)), \"\\n\")\n",
                               "result = (ergebnis = e, druck = _dr(e), zusammenfassung = z, druck_zusammenfassung = _dr(z))")))
}

# Tabellenzeilen: simulation() (ZS), Baustein bzw. Konstruktor (ZB), tax_tariff() aus Zeilen L (ZT)
ZS <- function(z, a = list(), d = "dT", s = "s2", extra = list(), pre = NULL) {
  k <- simcode(a, d, s, extra)
  list(z = z, r = .vor(pre, "r", k$r), py = .vor(pre, "py", paste0("result = ", k$py)), jl = .vor(pre, "jl", paste0("result = ", k$jl)),
       inputs = k$inputs)
}
ZB <- function(z, b, inputs = list(), print = NA)
  list(z = z, r = em(b, "r"), py = paste0("result = ", em(b, "py")), jl = paste0("result = ", em(b, "jl")), inputs = inputs, print = print)
TAB <- function(id, prueft, zeilen) {
  inp <- list()
  for (z in zeilen) for (k in names(z$inputs)) {
    if (!is.null(inp[[k]]) && !identical(inp[[k]], z$inputs[[k]])) stop("TAB ", id, ": Eingabe ", k, " doppelt verschieden")
    inp[[k]] <- z$inputs[[k]]
  }
  ref_tabelle(id, lapply(zeilen, function(z) { z$inputs <- NULL; z }), inputs = inp, note = paste("prüft:", prueft))
}

# Tarifdatei in jeder Sprache in eine temporäre Datei `f` schreiben (Zeilen aus der Eingabe L)
PRE_TT <- list(
  r = "f <- tempfile(fileext = '.csv'); writeLines(L, f)",
  py = "import os, tempfile\nfd, f = tempfile.mkstemp(suffix='.csv'); os.close(fd)\nwith open(f, 'w', encoding='utf-8') as fh:\n    fh.write('\\n'.join(np.atleast_1d(L)) + '\\n')",
  jl = 'f = tempname() * ".csv"; write(f, join(L isa AbstractString ? [L] : L, "\\n") * "\\n")')
# tax_tariff(f) mit Pfad 'F' in Ergebnis und Fehlermeldung (Pfade unterscheiden sich je Sprache)
ZT <- function(z, lines, var = "L") {
  pre <- lapply(PRE_TT, function(x) gsub("\\bL\\b", var, x))
  list(z = z, inputs = setNames(list(lines), var),
    r = paste0(pre$r, "\nx <- tryCatch(tax_tariff(f), error = function(e) stop(gsub(f, 'F', conditionMessage(e), fixed = TRUE), call. = FALSE))\nx$file <- 'F'\nx"),
    py = paste0(pre$py, "\ntry:\n    x = simlev.tax_tariff(file=f)\nexcept Exception as e:\n    raise ValueError(str(e).replace(f, 'F')) from None\nx.file = 'F'\nresult = x"),
    jl = paste0(pre$jl, '\nx = try\n    SL.tax_tariff(f)\ncatch e\n    error(replace(e isa ErrorException ? e.msg : sprint(showerror, e), f => "F"))\nend\nx["file"] = "F"\nresult = x'))
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
sC2 <- create_strategy(A = asset_config("etf", share = .5, spread = 0.1), B = asset_config("etf", share = .5, spread = 0.1))
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
dDup <- rbind(dT, dT[20, ]); dDup <- dDup[order(dDup$date), ]
d0 <- dT; d0$A[10] <- 0
dFmt <- dT; dFmt$date <- format(dFmt$date, "%d.%m.%Y")
dTxtNA <- dT; dTxtNA$A[10] <- NA; dTxtNA$date <- as.character(dTxtNA$date)    # Datum als Text und Kurslücke (LOCF)
na <- NA_real_
TT_OK <- c("# Geltung: Testtarif", "art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0",
           "zone,10001,10000,1,0,0.2,0", "soli,20350,,,5.5,11.9,")
ZC <- function(z, r, py, jl, inputs = list(), print = NA) list(z = z, r = r, py = paste0("result = ", py), jl = paste0("result = ", jl),
                                                              inputs = inputs, print = print)

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# fehler: je Funktion eine Tabelle (eine Zeile je Meldung; Wert-Zeilen nur für Grenzfälle mit Warnung)
# ════════════════════════════════════════════════════════════════════════════════════════════════════
ref_init("engine", gruppe = "fehler")
TAB("simulation", "Daten- und Argumentprüfungen von simulation() (Meldung je Zeile)", list(
  ZS("datum_doppelt", d = "dDup"),
  ZS("kurs_null", d = "d0"),
  ZS("datum_text_kein_datum", d = "dFmt"),
  ZS("kursspalte_fehlt", s = "sZ", extra = list(sZ = create_strategy(Z = asset_config("etf", spread = 0.1)))),
  ZS("kein_asset_am_ersten_tag", s = "sK", extra = list(sK = create_strategy(A = asset_config("etf", share = 1, start = as.Date("2020-01-15"), spread = 0.1)))),
  ZS("startwert_negativ", list(start_value = -5)),
  ZS("zeitraum_ein_tag", d = "d_one"),
  ZS("risk_free_als_anteil", list(risk_free = 0.01)),
  ZS("guenstigerpruefung_ohne_grenzsteuersatz", list(tax = BK("tax_profile", guenstigerpruefung = TRUE))),
  ZC("spalte_doppelt", "simulation(cbind(dT, dT['A']), s2)", "simlev.simulation(pd.concat([dT, dT[['A']]], axis=1), s2)",
     'SL.simulation(SL.RFrame(vcat(names(dT), "A"), AbstractVector[[dT[k] for k in names(dT)]..., dT["A"]]), s2)', list(dT = dT, s2 = s2)),
  ZS("fractions_zahl", list(fractions = 1)),
  ZS("costs_zahl", list(costs = 5)),
  ZS("dca_liste", list(dca = list(value = 100, span = 1))),
  ZS("basiszins_spalte_fehlt", list(tax = BK("tax_profile", base_rate = "br"))),
  ZS("ereignisgewicht_spalte_fehlt", list(event_col = "ev", event_weight = c(A = "wA", B = "xx")), d = "dE", s = "sC2"),
  ZS("ereignisgewicht_unbenannt", list(event_col = "ev", event_weight = c("wA", "wA")), d = "dE", s = "sC2"),
  ZS("ereignisgewicht_negativ", list(event_col = "ev", event_weight = c(A = "wN", B = "wN")), d = "dE", s = "sC2"),
  ZS("asset_start_nach_ende", list(start_value = 1e4), d = "d2", s = "sLate4"),
  ZS("sparplan_start_nach_ende", list(dca_mode = TRUE, dca_value = 1, dca_span = 1, dca_start = "2025-01-01")),
  ZS("umschichten_start_nach_ende", list(rebalance = BK("rebalance_plan", start = "2025-01-01"))),
  ZS("zve_jahr_fehlt", c(P(taxable_income = V("zve_2020")), EV_P), d = "dP", s = "sP", extra = list(zve_2020 = c("2020" = 74000))),
  ZS("zve_zwei_werte_unbenannt", P(taxable_income = c(1, 2))),
  ZS("tarifdatei_nicht_numerisch", P(taxable_income = 50000, tax_tariff = V("f")), extra = list(L_b = sub("0.2,0$", "zwei,0", TT_OK)),
     pre = lapply(PRE_TT, function(x) gsub("\\bL\\b", "L_b", x)))
))
TAB("asset_config", "Prüfungen von asset_config()", list(
  ZC("share_text", "asset_config('etf', share = '0.5')", "simlev.asset_config(asset_class='etf', share='0.5')", 'SL.asset_config("etf"; share = "0.5")'),
  ZC("start_kein_datum", "asset_config('etf', start = 'kein Datum')", "simlev.asset_config(asset_class='etf', start='kein Datum')",
     'SL.asset_config("etf"; start = "kein Datum")'),
  ZC("teilfreistellung_als_anteil", "asset_config('etf', partial_exemption = 0.3, spread = 0.1)",
     "simlev.asset_config(asset_class='etf', partial_exemption=0.3, spread=0.1)", 'SL.asset_config("etf"; partial_exemption = 0.3, spread = 0.1)')))
TAB("sim_costs", "Prüfungen von sim_costs()", list(
  ZB("feld_unbekannt", BK("sim_costs", order_fee = list(fix = 1))),
  ZB("text", BK("sim_costs", order_fee = "5")),
  ZB("negativ", BK("sim_costs", dca_fee = -1))))
TAB("dca_plan", "Prüfungen von dca_plan()", list(
  ZB("betrag_unendlich", BK("dca_plan", value = Inf, span = 1)),
  ZB("abstand_na", BK("dca_plan", value = 100, span = V("na")), inputs = list(na = na)),
  ZB("tag_32", BK("dca_plan", value = 100, span = 1, days = 32)),
  ZB("start_kein_datum", BK("dca_plan", value = 100, span = 1, start = "kein Datum")),
  ZB("skip_zahl", BK("dca_plan", value = 100, span = 1, skip = 1)),
  ZB("anker_unbekannt", BK("dca_plan", value = 100, span = 1, anchor = "mitte")),
  ZB("tage_doppelt", BK("dca_plan", value = 100, span = 1, days = c(5, 5)))))
TAB("rebalance_plan", "Prüfungen von rebalance_plan()", list(
  ZB("schwelle_negativ", BK("rebalance_plan", thresh = -1)),
  ZB("tag_40", BK("rebalance_plan", days = 40)),
  ZB("event_col_zahl", BK("rebalance_plan", event_col = 5)),
  ZB("schwellenart_unbekannt", BK("rebalance_plan", thresh_type = "prozent")),
  ZB("einheit_unbekannt", BK("rebalance_plan", unit = "nix")),
  ZB("schwelle_als_anteil", BK("rebalance_plan", thresh = 0.05)),
  ZB("event_mode_ohne_event_col", BK("rebalance_plan", event_mode = "replace")),
  ZB("event_weight_ohne_event_col", BK("rebalance_plan", event_weight = c(A = "wA"))),
  ZB("tage_doppelt", BK("rebalance_plan", days = c(1, 1)))))
TAB("split_rule", "Prüfungen von split_rule()", list(
  ZB("schwelle_fehlt", BK("split_rule")),
  ZB("ohne_100", BK("split_rule", c(150, 400)))))
TAB("tax_profile", "Prüfungen von tax_profile()", list(
  ZB("satz_150", BK("tax_profile", rate = 150)),
  ZB("satz_und_kirchensteuer", BK("tax_profile", rate = 25, church_tax = 9)),
  ZB("kirchensteuer_text", BK("tax_profile", church_tax = "9")),
  ZB("basiszins_zwei_werte", BK("tax_profile", base_rate = c(1, 2))),
  ZB("harvest_true", BK("tax_profile", harvest = TRUE)),
  ZB("income_zahl", BK("tax_profile", income = 42)),
  ZB("freigrenze_text", BK("tax_profile", private_sale_threshold = "1000")),
  ZB("pauschbetrag_negativ", BK("tax_profile", sparer_pauschbetrag = -1)),
  ZB("guenstigerpruefung_text", BK("tax_profile", guenstigerpruefung = "ja")),
  ZB("satz_als_anteil", BK("tax_profile", rate = 0.26375)),
  ZB("kirchensteuer_12", BK("tax_profile", church_tax = 12)),
  ZB("basiszins_als_anteil", BK("tax_profile", base_rate = 0.02))))
TAB("income_rate", "Prüfungen von income_rate()", list(
  ZB("satz_fehlt", BK("income_rate")),
  ZB("satz_60", BK("income_rate", 60)),
  ZB("soli_negativ", BK("income_rate", 42, soli_rate = -1)),
  ZB("satz_als_anteil", BK("income_rate", 0.42))))
TAB("income_tariff", "Prüfungen von income_tariff() (zvE als Zahl, benannter Vektor oder data.frame)", list(
  ZB("zve_fehlt", BK("income_tariff")),
  ZB("zve_text", BK("income_tariff", "50000")),
  ZB("tarif_zahl", BK("income_tariff", 50000, tariff = 42)),
  ZB("zwei_werte_unbenannt", BK("income_tariff", c(1, 2))),
  ZB("tabelle_spalten", BK("income_tariff", V("zve_abc")), inputs = list(zve_abc = data.frame(a = 2020, b = 1, c = 2))),
  ZB("tabelle_betrag_text", BK("income_tariff", V("zve_chr")), inputs = list(zve_chr = data.frame(year = 2020, taxable_income = "x"))),
  ZB("name_kein_jahr", BK("income_tariff", V("zve_x")), inputs = list(zve_x = c("2020" = 1, "x" = 2))),
  ZB("nan", BK("income_tariff", NaN)),
  ZB("jahr_doppelt", BK("income_tariff", V("zve_dup")), inputs = list(zve_dup = c("2020" = 1, "2020" = 2)))))
TAB("harvest_rule", "Prüfungen von harvest_rule()", list(
  ZB("tag_1231", BK("harvest_rule", day = "12-31")),
  ZB("verlusttopf_text", BK("harvest_rule", loss_pot = "ja"))))
TAB("funds_costs", "Prüfungen von funds_costs()", list(
  ZB("gebuehr_150", BK("funds_costs", fee = 150)),
  ZB("performance_fee_na", BK("funds_costs", performance_fee = V("na")), inputs = list(na = na))))
TB <- c("art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0"); TS <- "soli,20350,,,5.5,11.9,"
TAB("tax_tariff", "Prüfungen von tax_tariff() (Tarifdatei)", list(
  ZC("datei_fehlt", "tax_tariff('/nonexistent/gibt_es_nicht.csv')", "simlev.tax_tariff(file='/nonexistent/gibt_es_nicht.csv')",
     'SL.tax_tariff("/nonexistent/gibt_es_nicht.csv")'),
  ZC("file_zahl", "tax_tariff(42)", "simlev.tax_tariff(file=42)", "SL.tax_tariff(42)"),
  ZT("spalte_fehlt", sub(",c$", ",x", TT_OK), "L01"),
  ZT("art_unbekannt", sub("^zone,10001", "zonen,10001", TT_OK), "L02"),
  ZT("wert_nicht_numerisch", sub("0.2,0$", "zwei,0", TT_OK), "L03"),
  ZT("erste_zone_nicht_0", sub("^zone,0,", "zone,5,", TT_OK), "L04"),
  ZT("zonen_nicht_steigend", c(TT_OK[1:3], "zone,0,0,1,0,0,0", TT_OK[5]), "L05"),
  ZT("soli_fehlt", TT_OK[-5], "L06"),
  ZT("teiler_0", sub("10000,1,0,0.2", "10000,0,0,0.2", TT_OK), "L07"),
  ZT("soli_satz_155", sub("5.5,11.9", "155,11.9", TT_OK), "L08"),
  ZT("grenzsteuersatz_negativ", c(TB, "zone,10001,0,1,0,-0.1,1000.1", TS), "L09"),
  ZT("steuer_ueber_einkommen", c(TB, "zone,10001,0,1,0,0.2,50000", TS), "L10"),
  ZT("semikolon", gsub(",", ";", TT_OK), "L11"),
  ZT("dezimalkomma", sub("0.2,0$", "0,2,0", TT_OK), "L12"),
  ZT("keine_zone", c("art,ab,bezug,teiler,a,b,c", TS), "L13"),
  ZT("soli_freigrenze_negativ", c(TB, "zone,10001,10000,1,0,0.2,0", "soli,-5,,,5.5,11.9,"), "L14"),
  ZT("sprung_an_zonengrenze", c("# Kopf ohne Geltung", TB, "zone,10001,10000,1,0,0.25,0", "zone,50000.5,0,1,0,0.4,-7500.13", "soli,1e9,,,5.5,11.9,"), "L15")))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# ausgabe: Druck der Bausteine (Wert und print je Zeile)
# ════════════════════════════════════════════════════════════════════════════════════════════════════
ref_init("engine", gruppe = "ausgabe")
TAB("bausteine_druck", "Inhalt und Druck der Bausteine und von asset_config()", list(
  ZB("sim_costs_voll", BK("sim_costs", order_fee = list(fixed = 1.5, percent = 0.25, min = 3, max = 30), dca_fee = 0)),
  ZB("rebalance_plan_voll", BK("rebalance_plan", span = 2, days = 10, unit = "year", thresh = 25, thresh_type = "relative", start = "2021-01-01")),
  ZB("rebalance_plan_ereignis", BK("rebalance_plan", event_col = "ev", event_mode = "replace", skip = TRUE, event_weight = c(A = "wA", B = "wB"), thresh = 5)),
  ZB("tax_profile_voll", BK("tax_profile", church_tax = 9, sparer_pauschbetrag = 0, private_sale_threshold = 600, base_rate = "br",
     guenstigerpruefung = TRUE, income = BK("income_rate", 42, soli_rate = 5.5), harvest = BK("harvest_rule", day = "11-30", loss_pot = FALSE))),
  ZB("tax_profile_zve_jahre", BK("tax_profile", income = BK("income_tariff", V("zve_jahre"))), inputs = list(zve_jahre = c("2020" = 50000, "2021" = 52000))),
  ZB("income_rate", BK("income_rate", 24.5)),
  ZB("harvest_rule", BK("harvest_rule")),
  ZB("funds_costs", BK("funds_costs")),
  ZC("asset_config_etc", "asset_config('etc', 'bnh', 0.3, start = '2020-01-01', deliverable = TRUE, spread = 0.1)",
     "simlev.asset_config(asset_class='etc', trading='bnh', share=0.3, start='2020-01-01', deliverable=True, spread=0.1)",
     'SL.asset_config("etc", "bnh", 0.3; start = "2020-01-01", deliverable = true, spread = 0.1)')))
ref_done()

# ════════════════════════════════════════════════════════════════════════════════════════════════════
# szenario: je Szenario ein simulation()-Lauf, geprüft werden Ergebnis, Druck, summary(), details und Warnungen
# ════════════════════════════════════════════════════════════════════════════════════════════════════
ref_init("engine", gruppe = "gleichlauf")
SZ("tarif_steuerschuld_negativer_endwert", "Tarif (zvE 74 000), Steuer aus der Veranlagung größer als das Depot, negativer Endwert, details",
   c(P(taxable_income = 74000, details = TRUE), EV_P), d = "dR", s = "sP")
SZ("grenzsteuersatz_sparplan_ohne_zinsfuss", "§ 23-Steuer größer als Cash, nicht positiver TWR-Index, Sparplan ohne internen Zinsfuß",
   c(P(marginal_tax_rate = 42, dca_mode = TRUE, dca_value = 1000, dca_span = 1, dca_days = 30, dca_start = "2021-06-01"), EV_P), d = "dR", s = "sP")
SZ("guenstigerpruefung_zve_null", "Günstigerprüfung mit Tarif bei zvE 0, Ereignis-Umschichtung (skip), details",
   c(P(taxable_income = 0, use_guenstigerpruefung = TRUE, details = TRUE), EV_G), d = "dG", s = "sG")
SZ("tarif_zve_tabelle_spitzensteuersatz", "zvE als data.frame mit freien Spaltennamen, Spitzensteuersatz im Folgejahr, § 23",
   c(P(taxable_income = V("zve_yv")), EV_P), d = "dP", s = "sP", extra = list(zve_yv = data.frame(yr = 2020:2021, val = c(74000, 300000))))
SZ("freibetrag_mit_verlusttopf", "Freibetrag nutzen (harvest) mit Verlusttopf, Ereignis-Umschichtung, details",
   c(P(harvest_mode = TRUE, details = TRUE), EV_L), d = "dL", s = "sL")
SZ("spaeter_start_mit_sparplan", "Asset mit NA am Anfang (series_align range = all), Sparplan, summary()",
   list(dca_mode = TRUE, dca_value = 100, dca_span = 1), d = "dN", s = "sN")
SZ("datum_text_und_kursluecke", "Datum als Text (JJJJ-MM-TT) und Kurslücke (LOCF, Attribut filled)", list(), d = "dTxtNA")
SZ("privatverkauf_freigrenze_sparplan", "§ 23 mit Freigrenze 600, Pauschbetrag 801, Grenzsteuersatz 24, Sparplan an zwei Monatstagen (Anker Ende), liquidate, details",
   list(tax_mode = "person", private_sale_threshold = 600, sparer_pauschbetrag = 801, marginal_tax_rate = 24, liquidate = TRUE, details = TRUE,
        dca_mode = TRUE, dca_value = 100, dca_span = 1, dca_days = c(1, 15), dca_anchor = "end"), s = "sp")
SZ("liquidieren_gebuehr_ueber_erloes", "liquidate: Position bleibt stehen, weil die Ordergebühr den Erlös übersteigt (Warnung)",
   list(start_value = 100, order_fee = 60, liquidate = TRUE), d = "dK", s = "sC")
SZ("ereignis_gewicht_unvollstaendig", "event_weight nennt nicht alle Assets (Warnung), event_mode replace",
   list(event_col = "ev", event_weight = c(A = "wA"), event_mode = "replace"), d = "dE", s = "sC2")
set.seed(7); cal <- days("2019-10-01", "2020-03-31"); wd <- cal[!format(cal, "%u") %in% c("6", "7")]
us <- data.frame(date = wd, A = round(100 * exp(cumsum(rnorm(length(wd), 4e-4, 0.011))), 4))
ref_case("filled_nach_zeilenauswahl", note = "prüft: Attribut filled nach Zeilenauswahl einer series_align()-Tabelle (Warnung), Ergebnis und Druck",
         inputs = list(us = us, s1 = s1),
         r = "al <- series_align(A = us)\nsimulation(al[al$date >= as.Date('2020-01-01'), ], s1)",
         py = "al = simlev.series_align(A=us)\nresult = simlev.simulation(al[al['date'] >= np.datetime64('2020-01-01')], s1)",
         jl = 'al = SL.series_align(A = us)\nresult = SL.simulation(SL.rows(al, al["date"] .>= Date(2020, 1, 1)), s1)')

# Zufallskombinationen des bisherigen Generators (engine/zz09, zz21; gleiche Zufallsfolge)
TT_ALT <- c("# Geltung: Testtarif", "art,ab,bezug,teiler,a,b,c", "zone,0,0,1,0,0,0", "zone,10001,10000,1,0,0.2,-0.2",
            "zone,40001,0,1,0,0.4,-8000.4", "soli,15000,,,5.5,11.9,")
ZZ <- c(`9` = "privatverkauf_ohne_grenzsteuersatz",
        `21` = "eigener_tarif_mit_sprung")
ZZP <- c(`9` = "§ 23 ohne Grenzsteuersatz (zwei Warnungen), Basiszins, prozentuale Ordergebühr, ganze Stücke, liquidate",
         `21` = "eigene Tarifdatei mit Sprung an der Zonengrenze (Warnung), zvE 300 000, Freibetrag ohne Verlusttopf")
pick <- function(x) x[[sample.int(length(x), 1)]]
for (k in c(9, 21)) {
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
  if (tm == "funds" && runif(1) < 0.5) { a$funds_fee <- pick(c(0, 0.5, 2)); a$bonus_fee <- pick(c(0, 10, 20)) }   # Ziehungen bleiben (Zufallsfolge)
  if (runif(1) < 0.15) a$details <- TRUE
  if (runif(1) < 0.12) { bad <- pick(list(list(tax_rate = 0.26), list(church_tax = 0.08), list(church_tax = 12), list(balance_thresh = 0.05),
                                            list(order_fee = list(fix = 1)), list(harvest_day = "1231"),
                                            list(dca_days = c(1, 1, 15), dca_mode = TRUE, dca_value = 10, dca_span = 1),
                                            list(funds_fee = 1), list(taxable_income = c(1, 2)), list(spread = 0.1), list(marginal_tax_rate = 0.3),
                                            list(base_rate = 0.01), list(sparer_pauschbetrag = -1), list(fractions = 1),
                                            list(split_mode = TRUE, split_thresh = c(150, 400)), list(dca_value = 5), list(start_value = -5)))
    a[names(bad)] <- bad }
  if (tm == "funds") next   # Fondsmodus entfernt (seit 0.10.0): Fall entfällt, die übrigen bleiben gleich
  dname <- sprintf("dz%02d", k); sname <- sprintf("sz%02d", k)
  assign(dname, df); assign(sname, st)
  SZ(ZZ[[as.character(k)]], ZZP[[as.character(k)]], a, d = dname, s = sname, extra = extra, pre = pre)
}

# Szenarien aus den Engine-Zufallsgeneratoren tests/werkzeuge/zufall/engine_faelle.R (500 4711) und engine_stress.R
# (1000 90210; dort Zufallsprüfung im Gleichlauf, ohne abgelegte Fälle): Daten,
# Strategie und Argumente der genannten Fälle übernehmen (gleiche Zufallsfolge), als Szenario neu auswerten
golden_capture <- function(script, n, seed, ids) {
  txt <- readLines(script, encoding = "UTF-8")
  i <- grep("^run_case <- function\\(id, data, strategy, sargs\\) \\{", txt); stopifnot(length(i) == 1)
  txt[i] <- paste(txt[i], "if (id %in% .ids) .cap[[id]] <<- list(data = data, strategy = strategy, sargs = sargs); return(invisible(NULL))")
  env <- new.env(parent = globalenv())
  env$.ids <- ids; env$.cap <- list()
  out <- tempfile()
  env$commandArgs <- function(trailingOnly = FALSE)
    if (trailingOnly) c(out, n, seed) else c("R", paste0("--file=", normalizePath(script)), "--args", out, n, seed)
  env$cat <- function(...) invisible(NULL)
  eval(parse(text = txt, keep.source = FALSE), env)
  unlink(out, recursive = TRUE)
  stopifnot(setequal(names(env$.cap), ids))
  env$.cap
}
GF <- list(
  f23_legacy_list = c("strategie_als_liste", "Strategie als einfache Liste (ohne asset_config), liquidate", "60"),
  f24_vp_lastday = c("vorabpauschale_letzter_tag", "Vorabpauschale am letzten Datentag, Umschichten, details"),
  f26_details_full = c("details_quartal_schwelle_sparplan", "details mit Quartals-Umschichtung (Schwelle 2), Sparplan, Basiszins als Spalte, liquidate", "400"),
  f30_details_guenst_no = c("details_guenstigerpruefung_ohne_erstattung", "Günstigerprüfung ohne Erstattung (Grenzsteuersatz 35), details"),
  f32_start_on_gap = c("start_auf_wochenende", "später startende Assets mit Start auf einem Tag ohne Kurs (nur Werktage), details, liquidate", "1000"),
  f36_details_ps_long = c("privatverkauf_sparplan_tag_29", "§ 23 mit Freigrenze 600, Sparplan am 29. (Februar), monatliches Umschichten, details", "1000"),
  f38_numeric_signals = c("signale_als_zahlen", "Signalspalten numerisch 0/1, Quartals-Umschichtung, liquidate", "60"),
  r375 = c("signal_etf_split_negativer_basiszins", "Signal-ETF allein mit Split-Regel, jährlichem Umschichten und negativem Basiszins", "60"))
GS <- list(
  x05_crash_int_shares = c("fallende_hebelreihe_ganze_stuecke", "fallende Hebelreihe mit ganzen Stücken, Startwert 500 EUR, Sparplan mit Umschichten (balance_dca)", "60"),
  x11_multi_signal_details = c("mehrere_signale_details", "mehrere Signal-Assets, Grenzsteuersatz 14, details", "500"),
  x13_tiny_start = c("winziger_startwert", "Startwert 0,01 EUR über 500 Tage, Umschichten, liquidate", "500"),
  x23_unsorted = c("daten_unsortiert", "Daten nicht nach Datum sortiert"),
  y0886 = c("spaeter_start_splits_signal_cash", "später startende Assets mit Splits vor dem Start (ohne Bestand), Reverse-Split im Bestand, Signal-Asset hält Cash, Ereignis-Umschichtung, details",
            "2034-06-01", "2037-06-30"))
for (g in list(list("engine_faelle.R", 500, 4711, GF), list("engine_stress.R", 1000, 90210, GS))) {
  cap <- golden_capture(file.path("tests", "werkzeuge", "zufall", g[[1]]), g[[2]], g[[3]], names(g[[4]]))
  for (id in names(g[[4]])) {
    x <- cap[[id]]; nm <- g[[4]][[id]]
    if (length(nm) == 4) { x$data <- x$data[x$data$date >= as.Date(nm[3]) & x$data$date <= as.Date(nm[4]), ]; rownames(x$data) <- NULL }   # Ausschnitt
    if (length(nm) == 3) x$data <- x$data[seq_len(min(nrow(x$data), as.integer(nm[3]))), ]          # erste Zeilen
    if (id == "f26_details_full") {   # Basiszins als Spalte statt als Zahl (gleicher Wert)
      x$data$br <- x$sargs$base_rate; x$sargs$base_rate <- NULL; x$sargs$base_rate_flex <- TRUE; x$sargs$base_rate_data <- "br"
    }
    SZ(nm[1], nm[2], x$sargs, d = "dg", s = "sg", extra = list(dg = x$data, sg = x$strategy))
  }
}
ref_done()
ref_schreiben()
