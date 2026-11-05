# tests/werkzeuge/gleichlauf/wd_fuzz.R – Fuzz der Entnahme-Auswertung (seit 1.5.0: Kennzahlen je Pfad, Perfect
# Withdrawal Rate, Jahresprodukte und Jahreszeilen des Tarifwegs im Kern core/withdrawal_core_impl.h)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/wd_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul wd_fuzz:
#   - p-Fälle (etwa ein Fünftel): withdrawal_perfect_rate() direkt mit Matrizen (1 bis 40 Jahre, 1 bis 12 Pfade, mit
#     und ohne Spaltennamen, ganzzahlig), Vektoren, Totalverlust (0), legacy (auch ungültig), Fehlern (NA, Inf,
#     negativ, Median < 0.5).
#   - s-Fälle: withdrawal_simulation() mit allen Regeln (ohne cape), jährlich, quartalsweise und monatlich (auch
#     Rumpfjahr und weniger als ein Jahr), 1 bis 150 Pfaden, Renditen mit Totalverlust, Inflation als Zahl oder Matrix
#     (auch so hoch, dass die PWR-Prüfung "Median < 0.5" abbricht, auch 0 und Inf: Entnahmen Inf/NaN), gamma 0, 0.5,
#     1, 1 + 1e-13, 2, 7, Startwerten bis 1e-300, Einkommen (auch negativ), Entnahme am Periodenende, years,
#     keep_paths, Steuern (tax_profile()) und Tarifweg (income_tariff(), Jahreszeilen), Horizont (Zahl, uniform,
#     discrete, normal, triangular; mit Kürzung).
#   - m-Fälle (etwa ein Zehntel): withdrawal_max_rate() mit kleinen Matrizen (Bisektion über withdrawal_simulation()).
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R; das Feld elapsed ist 0 gesetzt.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261105)
ref_bereich("wd_fuzz", alle = TRUE); ref_init("wd_fuzz")
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
num <- function(v) sprintf("%.17g", v)
PH <- "import math, simlev\nimport numpy as np\nimport simlev._r.fmt\nfrom simlev.withdrawal import *\n"
JH <- "using SimLev.Withdrawal\n"
# Argumente als Tripel (R, Python, Julia); arg() baut daraus die Aufrufe
A <- function(r, py = r, jl = r) list(r = r, py = py, jl = jl)
nv <- function(v) A(num(v))
call3 <- function(fn, first, pos = NULL, args = list()) {
  ra <- c(first$r, if (!is.null(pos)) pos$r, vapply(names(args), function(k) sprintf("%s = %s", k, args[[k]]$r), ""))
  pa <- c(first$py, if (!is.null(pos)) sprintf("rule=%s", pos$py), vapply(names(args), function(k) sprintf("%s=%s", k, args[[k]]$py), ""))
  ja <- c(first$jl, if (!is.null(pos)) pos$jl)
  jk <- vapply(names(args), function(k) sprintf("%s = %s", k, args[[k]]$jl), "")
  list(r = sprintf("%s(%s)", fn, paste(ra, collapse = ", ")), py = sprintf("%s(%s)", fn, paste(pa, collapse = ", ")),
       jl = sprintf("%s(%s%s)", fn, paste(ja, collapse = ", "), if (length(jk)) paste0("; ", paste(jk, collapse = ", ")) else ""))
}
rule3 <- function(type, extra = list()) {
  ra <- c(sprintf("'%s'", type), vapply(names(extra), function(k) sprintf("%s = %s", k, extra[[k]]), ""))
  pa <- c(sprintf("type='%s'", type), vapply(names(extra), function(k) sprintf("%s=%s", k, extra[[k]]), ""))
  jk <- vapply(names(extra), function(k) sprintf("%s = %s", k, extra[[k]]), "")
  A(sprintf("withdrawal_rule(%s)", paste(ra, collapse = ", ")), sprintf("withdrawal_rule(%s)", paste(pa, collapse = ", ")),
    sprintf('withdrawal_rule("%s"%s)', type, if (length(jk)) paste0("; ", paste(jk, collapse = ", ")) else ""))
}
returns <- function(nper, npath, ppy) {
  mu <- pick(c(0.05, 0.02, -0.02, 0.1)) / ppy; s <- pick(c(0, 0.05, 0.15, 0.3)) / sqrt(ppy)
  R <- matrix(exp(rnorm(nper * npath, mu, s)), nper, npath)
  if (coin(0.15)) R[sample.int(length(R), max(1, length(R) %/% 50))] <- 0          # Totalverlust
  if (coin(0.1)) R <- round(R, 2)
  R
}
rules <- c("constant", "constant", "percent", "vanguard", "guyton_klinger", "floor_ceiling", "clyatt", "ratchet",
           "endowment", "one_over_n", "vpw", "abw", "sensible", "hebeler")
np_ <- round(N * 0.2); nm <- round(N * 0.1); ns <- N - np_ - nm

for (k in seq_len(np_)) {   # p-Fälle: withdrawal_perfect_rate()
  set.seed(seed0 + k)
  ny <- pick(c(1, 2, 3, 5, 10, 30, 40)); npath <- pick(c(1, 1, 2, 5, 12))
  R <- matrix(exp(rnorm(ny * npath, pick(c(0.03, 0, -0.5)), pick(c(0, 0.1, 0.3)))), ny, npath)
  if (coin(0.15)) R[sample.int(length(R), 1)] <- 0
  if (coin(0.06)) R[sample.int(length(R), 1)] <- pick(c(NA, NaN, Inf, -Inf, -0.1))
  if (coin(0.05)) R <- R * pick(c(0.1, 0.4))                                         # Median < 0.5
  if (coin(0.25)) colnames(R) <- paste0("k", seq_len(npath))
  if (coin(0.05)) { R <- round(R * 2); storage.mode(R) <- "integer" }
  vecf <- coin(0.15)
  leg <- if (coin(0.3)) pick(list(0.5, 1, 0, 2.5, -1, NA, c(1, 2), "a")) else NULL
  lr <- if (is.null(leg)) "" else sprintf(", legacy = %s", if (is.character(leg)) "'a'" else if (length(leg) > 1) "c(1, 2)" else num(leg))
  lp <- if (is.null(leg)) "" else sprintf(", legacy=%s", if (is.character(leg)) "'a'" else if (length(leg) > 1) "[1, 2]" else if (is.na(leg)) "simlev._r.fmt.NA_REAL" else num(leg))
  lj <- if (is.null(leg)) "" else sprintf("; legacy = %s", if (is.character(leg)) "\"a\"" else if (length(leg) > 1) "[1, 2]" else if (is.na(leg)) "SL.NA" else num(leg))
  x <- if (vecf) "R[, 1]" else "R"
  fuzz_case(sprintf("p%05d", k), r = sprintf("withdrawal_perfect_rate(%s%s)", x, lr),
            py = sprintf("%sresult = withdrawal_perfect_rate(%s%s)", PH, if (vecf) "np.asarray(R, dtype=float)[:, 0]" else "R", lp),
            jl = sprintf("%sresult = withdrawal_perfect_rate(%s%s)", JH, if (vecf) "R[:, 1]" else "R", lj),
            inputs = list(R = R))
}

sim_args <- function(R, ppy, freq, allow_h = TRUE) {
  a <- list()
  if (freq != "year") a$frequency <- A(sprintf("'%s'", freq), sprintf("'%s'", freq), sprintf('"%s"', freq))
  u <- runif(1)
  if (u < 0.6) a$inflation <- nv(pick(c(0, 2, 2.5, -1, 10)))
  else if (u < 0.75) a$inflation <- A("Im")
  if (coin(0.5)) a$start_value <- nv(pick(c(1e6, 5e5, 1, 1e-300, 3e4)))
  if (coin(0.3)) a$gamma <- nv(pick(c(0, 0.5, 1, 1 + 1e-13, 2, 7)))
  if (coin(0.2)) a$timing <- A("'end'", "'end'", '"end"')
  if (coin(0.2)) {
    s1 <- pick(c(1, 2, 3.5)); e1 <- pick(c(4, 8.2, 50)); am <- pick(c(5000, 20000, -3000))
    a$income <- A(sprintf("list(list(start = %s, end = %s, amount = %s))", num(s1), num(e1), num(am)),
                  sprintf("[{'start': %s, 'end': %s, 'amount': %s}]", num(s1), num(e1), num(am)),
                  sprintf('[Dict("start" => %s, "end" => %s, "amount" => %s)]', num(s1), num(e1), num(am)))
  }
  if (coin(0.15)) a$years <- nv(pick(c(1, 2, 5, 0.5, 10)))
  if (coin(0.3)) a$keep_paths <- pick(list(A("FALSE", "False", "false"), nv(pick(c(1, 3)))))
  u <- runif(1)
  if (u < 0.25) {
    a$tax <- A("tax_profile()", "simlev.tax_profile()", "SL.tax_profile()")
    if (coin(0.5)) a$cost_basis <- nv(pick(c(60, 100, 30)))
    if (coin(0.5)) a$base_rate <- nv(pick(c(2.5, 0, 4)))
  } else if (u < 0.4) {
    zv <- pick(c(4000, 30000, 90000)); gp <- coin(0.5); ct <- pick(c(0, 8, 9))
    a$tax <- A(sprintf("tax_profile(church_tax = %s, guenstigerpruefung = %s, income = income_tariff(%s))", num(ct), if (gp) "TRUE" else "FALSE", num(zv)),
               sprintf("simlev.tax_profile(church_tax=%s, guenstigerpruefung=%s, income=simlev.income_tariff(%s))", num(ct), if (gp) "True" else "False", num(zv)),
               sprintf("SL.tax_profile(; church_tax = %s, guenstigerpruefung = %s, income = SL.income_tariff(%s))", num(ct), if (gp) "true" else "false", num(zv)))
    a$cost_basis <- nv(pick(c(40, 60, 100)))
    if (coin(0.6)) a$base_rate <- nv(pick(c(2.5, 2)))
  }
  if (allow_h && coin(0.3)) {
    hs <- sample.int(9999, 1); hm <- pick(c(4, 9, 45))
    a$horizon <- pick(list(nv(pick(c(1, 3, 20, 60))),
      A(sprintf("withdrawal_horizon('uniform', min = 1, max = %d, seed = %d)", hm, hs),
        sprintf("withdrawal_horizon(type='uniform', min=1, max=%d, seed=%d)", hm, hs),
        sprintf('withdrawal_horizon("uniform"; min = 1, max = %d, seed = %d)', hm, hs)),
      A(sprintf("withdrawal_horizon('discrete', years = c(2, 5, 30), prob = c(1, 2, 1), seed = %d)", hs),
        sprintf("withdrawal_horizon(type='discrete', years=[2, 5, 30], prob=[1, 2, 1], seed=%d)", hs),
        sprintf('withdrawal_horizon("discrete"; years = [2, 5, 30], prob = [1, 2, 1], seed = %d)', hs)),
      A(sprintf("withdrawal_horizon('normal', mean = 8, sd = 4, min = 1, max = 30, seed = %d)", hs),
        sprintf("withdrawal_horizon(type='normal', mean=8, sd=4, min=1, max=30, seed=%d)", hs),
        sprintf('withdrawal_horizon("normal"; mean = 8, sd = 4, min = 1, max = 30, seed = %d)', hs)),
      A(sprintf("withdrawal_horizon('triangular', min = 1, mode = 3, max = 12, seed = %d)", hs),
        sprintf("withdrawal_horizon(type='triangular', min=1, mode=3, max=12, seed=%d)", hs),
        sprintf('withdrawal_horizon("triangular"; min = 1, mode = 3, max = 12, seed = %d)', hs))))
  }
  a
}
for (k in seq_len(ns)) {   # s-Fälle: withdrawal_simulation()
  set.seed(seed0 + 100000 + k)
  freq <- pick(c("year", "year", "year", "quarter", "month"))
  ppy <- switch(freq, year = 1, quarter = 4, month = 12)
  nper <- if (ppy == 1) pick(c(1, 2, 5, 10, 30, 40)) else pick(c(ppy %/% 2, ppy, ppy + 1, 3 * ppy, 10 * ppy + 2, 20 * ppy))
  nper <- max(1, nper)
  npath <- pick(c(1, 2, 5, 30, 150))
  R <- returns(nper, npath, ppy)
  Im <- matrix(pick(c(1, 1.002, 1.02)) * exp(rnorm(nper * npath, 0, 0.01)), nper, npath)
  if (coin(0.1)) Im <- Im * pick(c(3, 0.2))                                       # PWR: Median < 0.5 bzw. sehr hoch
  if (coin(0.05)) Im[sample.int(length(Im), 1)] <- pick(c(0, Inf, 1e-300))         # Entnahmen Inf/NaN (min/max mit NaN)
  type <- pick(rules)
  ex <- list()
  if (type %in% c("constant", "percent", "vanguard", "guyton_klinger", "floor_ceiling", "clyatt", "ratchet", "endowment", "sensible"))
    if (coin(0.6)) ex$rate <- num(pick(c(3, 4, 5, 8, 15)))
  rl <- rule3(type, ex)
  a <- sim_args(R, ppy, freq)
  cl <- call3("withdrawal_simulation", A("R"), rl, a)
  fuzz_case(sprintf("s%05d", k),
            r = paste0("ws <- ", cl$r, "; ws$elapsed <- 0; ws"),
            py = paste0(PH, "ws = ", cl$py, "; ws['elapsed'] = 0; result = ws"),
            jl = paste0(JH, "ws = ", cl$jl, "; ws[\"elapsed\"] = 0; result = ws"),
            inputs = list(R = R, Im = Im))
}

for (k in seq_len(nm)) {   # m-Fälle: withdrawal_max_rate()
  set.seed(seed0 + 200000 + k)
  nper <- pick(c(5, 10, 30)); npath <- pick(c(1, 5, 40))
  R <- returns(nper, npath, 1)
  Im <- matrix(1.02, nper, npath)
  type <- pick(c("constant", "constant", "percent", "guyton_klinger", "floor_ceiling"))
  a <- list(success = nv(pick(c(0.5, 0.9, 0.95, 1))))
  if (coin(0.3)) a$tol <- nv(pick(c(0.01, 0.1)))
  if (coin(0.5)) a$inflation <- nv(2)
  if (coin(0.2)) a$tax <- A("tax_profile()", "simlev.tax_profile()", "SL.tax_profile()")
  if (coin(0.2)) a$horizon <- nv(pick(c(3, 8)))
  if (coin(0.2)) a$gamma <- nv(1)
  cl <- call3("withdrawal_max_rate", A("R"), rule3(type), a)
  fuzz_case(sprintf("m%05d", k), r = cl$r, py = paste0(PH, "result = ", cl$py), jl = paste0(JH, "result = ", cl$jl),
            inputs = list(R = R, Im = Im))
}
ref_done(); ref_schreiben()
