# tools/gleichlauf/metric_fuzz.R – Fuzz der Kennzahlen (E17 Stufe 3: Auswertung von simulation() im Kern)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_MODULE_DIR=<ordner> Rscript tools/gleichlauf/metric_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Modulreferenzen (golden/modules/ref_tools.R) als Modul metric_fuzz:
#   - x-Fälle (gut ein Viertel): der interne Zinsfuß .xirr_rate direkt (R intern, Python simlev.engine.xirr_rate,
#     Julia SL.xirr_rate) mit Einzahlungen und Entnahmen, Endwerten 0, klein, groß und negativ, Laufzeiten 0,
#     negativ, NA, sehr kurz und lang, NA/Inf-Beträgen, Beinahe-Totalverlust (Nullstelle unter u = -200), sehr
#     hohen Renditen und Beträgen bis 1e300 (uniroot ersetzt nicht endliche Werte, mit Warnung).
#   - m-Fälle: simulation() mit Schwerpunkt Auswertung: Kursverläufe konstant (Standardabweichung 0), steigend
#     (kein Drawdown), Crash bis fast 0, Verzehnfachung, zufällig, mit NA; Einzeltag, zwei bis fünf Tage; Lücken
#     (aufgefüllte Tage aus den Renditen); Sparplan (XIRR, zeitgewichteter Index) auch mit hohen Kaufkosten auf
#     einem fast leeren Depot; Steuer mit Crash (§ 23-Gewinn, Umschichtung per Ereignis-Spalte, Crash vor dem
#     Jahresende wie um01 in gen_engine.R: offene Steuerschuld, negativer Endwert, Wertindex <= 0); risk_free als
#     Zahl (auch negativ und unter -100 %: Abbruch in .sim_risk_stats), Spalte (Zahlen, NA, Text mit
#     Umwandlungswarnung), fehlende Spalte (Fehler nach den Warnungen der Renditen), NULL, Vektor.
# Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tools/gleichlauf/run.sh, Schritt 5): Referenz aus R 1.3.0 (R_LIBS=/home/claude/rlib130), R neu mit
# tools/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit compare_reference gegen die Referenz.
source("golden/modules/ref_tools.R")
source("golden/tools/blocks_from_flat.R")
local({   # Code-Erzeuger aus gen_engine.R (em, .args, sim_code), ohne dessen Fälle
  ex <- parse("golden/modules/gen_engine.R", keep.source = FALSE)
  want <- c("V", ".num1", ".str1", "em", ".args", "sim_code")
  for (e in ex) if (is.call(e) && identical(e[[1L]], as.name("<-")) && is.name(e[[2L]]) && as.character(e[[2L]]) %in% want)
    eval(e, envir = globalenv())
})
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261103)
ref_init("metric_fuzz")
pick <- function(x) x[[sample.int(length(x), 1L)]]
coin <- function(p) runif(1) < p

# Fall schreiben und die Aufrufe der Warnungen und des Fehlers (nur R) als r_calls nachtragen (wie sim_fuzz.R)
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
  f <- file.path(.ref$outdir, sprintf("%s.json.gz", id))
  case <- jsonlite::fromJSON(gzfile(f), simplifyVector = FALSE)
  case$r_calls <- list(warnings = as.list(wc), error = ec)
  .ref_gz_write(.ref_json(case), sub("\\.gz$", "", f))
}

nx <- round(N * 0.27)
for (k in seq_len(nx)) {   # x-Fälle: .xirr_rate
  set.seed(seed0 + k)
  h <- pick(list(1, 2.5, 10, 40, 1 / 365.25, 0.01, 0, -1, NA_real_))
  m <- pick(c(1, 1, 2, 3, 5, 12, 40))
  hh <- if (is.finite(h) && h > 0) h else 1
  t <- sort(c(0, if (m > 1) round(runif(m - 1, 0, hh), 6)))
  amt <- c(pick(c(1e4, 1, 1e-6, 5e5)), if (m > 1) round(runif(m - 1, 10, 2000), 2))
  if (coin(0.2)) amt[sample.int(m, 1)] <- -amt[sample.int(m, 1)] * runif(1, 0.1, 3)   # Entnahme
  if (coin(0.08)) amt[sample.int(m, 1)] <- pick(c(NA, Inf, -Inf, 0))
  if (coin(0.06)) amt <- amt * pick(c(1e200, 1e250, 1e300))                            # uniroot: Inf ersetzt
  tot <- sum(amt[is.finite(amt)])
  ev <- pick(list(0, 0, tot * runif(1, 0.5, 2), tot * runif(1, 1e-9, 1e-4), tot * 1e-60, tot * pick(c(10, 1e3, 1e8)),
                  -abs(tot) * 0.1, tot, NA_real_, Inf))
  if (coin(0.1)) ev <- tot * exp(-runif(1, 50, 900))                                     # Beinahe-Totalverlust
  if (coin(0.08)) {   # Nullstelle knapp unter dem Überlauf: uniroot ersetzt Inf durch DBL_MAX (Warnungen)
    h <- pick(list(1, 2)); m <- pick(c(1, 2))
    t <- c(0, if (m > 1) h / 2); amt <- c(1e300, if (m > 1) 1e299)
    ev <- 1e300 * exp(runif(1, 15.2, 19.3) * pick(c(1, 1.02)))
  }
  in_ <- list(t = t, a = amt, ev = ev, h = h)
  fuzz_case(sprintf("x%05d", k),
            r = "result <- SimLev:::.xirr_rate(t, a, ev, h)",
            py = "result = simlev.engine.xirr_rate(t, a, ev, h)",
            jl = "result = SL.xirr_rate(t, a, ev, h)", inputs = in_)
}

classes <- c("etf", "etf", "etc", "certificate")
for (k in seq_len(N - nx)) {   # m-Fälle: simulation()
  set.seed(seed0 + 100000 + k)
  n <- pick(c(1, 2, 3, 4, 5, 10, 30, 60, 200, 400, 800, 1500))
  start <- as.Date("1995-01-01") + sample.int(9000, 1)
  d <- data.frame(date = seq.Date(start, by = "day", length.out = n))
  na <- pick(c(1, 1, 2))
  shape <- pick(c("random", "random", "const", "up", "crash", "boom", "na"))
  if (coin(0.15)) {   # § 23-Gewinn realisieren, dann Crash vor dem Jahresende: Steuer > Depot (offene Steuerschuld)
    y <- sample(1996:2019, 1)
    d <- data.frame(date = seq.Date(as.Date(sprintf("%d-01-01", y)), as.Date(sprintf("%d-%02d-28", y + 1, sample(1:12, 1))), by = "day"))
    t1 <- as.Date(sprintf("%d-%02d-01", y, sample(3:6, 1))); t2 <- t1 + sample(20:60, 1)
    t3 <- as.Date(sprintf("%d-%02d-01", y, sample(9:12, 1)))
    d$G <- ifelse(d$date < t1, 100, round(100 * runif(1, 1.2, 3), 2))
    d$H <- ifelse(d$date < t3, 50, 50 * pick(c(0.2, 0.02, 0.001)))
    d$ev <- d$date == t2; d$wG <- 0; d$wH <- 1
    s <- create_strategy(G = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE),
                         H = asset_config("etc", "bnh", share = 0.5, spread = 0, deliverable = TRUE))
    a <- list(start_value = pick(c(1e4, 1e5)), tax_mode = "person", event_col = "ev", event_mode = "replace",
              event_weight = list(G = "wG", H = "wH"))
    if (coin(0.5)) a$marginal_tax_rate <- 42 else a$taxable_income <- pick(c(40000, 74000))
    if (coin(0.5)) {
      a$dca_mode <- TRUE; a$dca_value <- pick(c(100, 1000, 5000)); a$dca_span <- 1
      a$dca_start <- format(pick(list(t1, t3 + 31, as.Date(sprintf("%d-02-01", y + 1)))))
      if (coin(0.4)) a$dca_fee <- pick(list(5, list(percent = 1)))
    }
    if (coin(0.3)) a$liquidate <- TRUE
    if (coin(0.3)) a$risk_free <- pick(list(1, "fehlt"))
    bl <- blocks_from_flat(a)
    fuzz_case(sprintf("m%05d", k), r = sim_code("d", "s", bl, "r"), py = paste0("result = ", sim_code("d", "s", bl, "py")),
              jl = paste0("result = ", sim_code("d", "s", bl, "jl")), inputs = list(d = d, s = s))
    next
  }
  for (j in seq_len(na)) {
    p0 <- runif(1, 20, 300)
    p <- switch(shape,
      const = rep(p0, n),
      up = p0 * cumprod(1 + abs(rnorm(n, 5e-4, 2e-3))),
      crash = p0 * cumprod(c(1, rep(exp(log(pick(c(1e-3, 1e-6, 0.05))) / max(1, n - 1)), n - 1))),
      boom = p0 * cumprod(c(1, rep(exp(log(pick(c(10, 1e3))) / max(1, n - 1)), n - 1))),
      p0 * cumprod(1 + rnorm(n, 2e-4, pick(c(0.005, 0.02, 0.05)))))
    if (shape == "na" && n > 3) p[sample(2:n, max(1, n %/% 10))] <- NA
    if (j == 2 && coin(0.3)) p <- rep(p0, n)
    d[[LETTERS[j]]] <- signif(p, 8)
  }
  nm <- LETTERS[seq_len(na)]
  sh <- if (na == 1) 1 else pick(list(c(0.5, 0.5), c(0.7, 0.3)))
  st <- lapply(seq_len(na), function(j) list(asset_class = pick(classes),
                                             trading = "bnh", share = sh[j], spread = pick(list(NULL, 0, 0.5))))
  names(st) <- nm
  if (n > 10 && coin(0.3)) {   # Lücken (aufgefüllte Tage)
    keep <- sort(unique(c(1, n, sample(2:(n - 1), floor((n - 2) * runif(1, 0.3, 0.95))))))
    d <- d[keep, , drop = FALSE]; rownames(d) <- NULL
  }
  nr <- nrow(d)
  a <- list(start_value = pick(c(1e4, 1e4, 500, 1, 1e6)))
  if (coin(0.6)) {
    a$dca_mode <- TRUE; a$dca_value <- pick(c(50, 1000, 1e5)); a$dca_unit <- pick(c("month", "month", "quarter", "year"))
    a$dca_span <- pick(c(1, 1, 2))
    if (coin(0.3)) a$dca_days <- pick(list(1, 15, c(1, 15)))
    if (coin(0.3)) a$dca_fee <- pick(list(1, 50, list(percent = 0.5), list(fixed = 40, percent = 1)))
  }
  if (coin(0.25)) a$order_fee <- pick(list(1, 4.95, 100, list(percent = 0.25, min = 1)))
  if (na > 1 && coin(0.4)) { a$balance_mode <- TRUE; a$balance_unit <- pick(c("month", "quarter", "year")) }
  if (coin(0.35)) {
    a$tax_mode <- "person"
    if (coin(0.4)) a$base_rate <- pick(c(1.5, 2.55, 4))
    if (coin(0.2)) a$sparer_pauschbetrag <- 0
  }
  rfc <- NULL
  u <- runif(1)
  if (u < 0.2) a$risk_free <- pick(c(0, 1, 2.5, 5, 0.01))
  else if (u < 0.27) a$risk_free <- pick(c(-50, -99, -150, -250))
  else if (u < 0.45) {
    rfc <- pick(c("num", "num", "na", "chr", "lgl"))
    d$rf <- switch(rfc,
      num = round(runif(nr, -1, 6), 3),
      na = { x <- round(runif(nr, 0, 4), 3); x[sample.int(nr, max(1, nr %/% 4))] <- NA; x },
      chr = { x <- as.character(round(runif(nr, 0, 4), 3)); if (nr > 1) x[sample.int(nr, 1)] <- pick(c("x", "", "1e1", " 2 ")); x },
      lgl = runif(nr) < 0.5)
    a$risk_free <- "rf"
  } else if (u < 0.5) a$risk_free <- pick(c("fehlt", "rf"))   # Spalte fehlt: Fehler nach den Warnungen
  if (coin(0.25)) a$liquidate <- TRUE
  if (coin(0.15)) a$fractions <- FALSE
  bl <- blocks_from_flat(a)
  s <- do.call(create_strategy, lapply(st, function(x) do.call(asset_config, x[!vapply(x, is.null, NA)])))
  fuzz_case(sprintf("m%05d", k), r = sim_code("d", "s", bl, "r"), py = paste0("result = ", sim_code("d", "s", bl, "py")),
            jl = paste0("result = ", sim_code("d", "s", bl, "jl")), inputs = list(d = d, s = s))
}
ref_done()
