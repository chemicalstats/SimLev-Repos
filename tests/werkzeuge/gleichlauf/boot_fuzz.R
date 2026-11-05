# tests/werkzeuge/gleichlauf/boot_fuzz.R – Fuzz des Pfadaufbaus im Bootstrap (seit 1.6.0 im Kern,
# core/slc_bootpath.cpp sl_boot_path; bis 1.5.2 je Sprache .build_path/_build_path je Pfad).
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/boot_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul boot_fuzz:
# bootstrap() mit 1 bis 3 Indizes (Kurse oder Renditen), Hebelprodukten (Hebel -3 bis 25, Finanzierung als Zahl oder
# Zusatzreihe, Tage als Zahl oder Zusatzreihe, Kosten), Zusatzreihen ("rate" mit NA und "level"), Knockouts,
# Verfahren raw/block/circular/stationary/wild/reset/tails/regime/garch, verschiedenen Pfadlängen. Verglichen werden
# die Pfade, ihre Niveau-Varianten (aux_level) und die Zählungen. Warnungen und Fehler mit Aufrufen wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261114)
ref_bereich("boot_fuzz", alle = TRUE); ref_init("boot_fuzz")
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
# Wert in R-, Python- und Julia-Schreibweise
em <- function(v, L) if (is.character(v)) switch(L, jl = sprintf("\"%s\"", v), sprintf("'%s'", v)) else num(v)

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  n <- pick(c(30, 120, 400)); ni <- pick(c(1, 2, 2, 3)); ix <- c("us", "eu", "jp")[seq_len(ni)]
  prices <- coin(0.6)
  d <- data.frame(t = seq_len(n))
  for (a in ix) {
    r <- 1 + rnorm(n, 3e-4, pick(c(0.005, 0.01, 0.03)))
    d[[a]] <- if (prices) round(100 * cumprod(r), 6) else round(r, 8)
  }
  aux <- character(0); at <- character(0)
  if (coin(0.6)) { v <- round(2 + cumsum(rnorm(n, 0, 0.05)), 4); if (coin(0.3)) v[sample.int(n, 2)] <- NA; d$rate <- v; aux <- c(aux, rate = "rate") }
  if (coin(0.4)) { d$cpi <- round(100 * cumprod(1 + rnorm(n, 2e-4, 1e-3)), 5); aux <- c(aux, cpi = "cpi"); if (coin(0.7)) at <- c(at, cpi = "level") }
  if (coin(0.3)) { d$days <- sample(c(1, 1, 1, 3), n, TRUE); aux <- c(aux, days = "days") }
  nl <- pick(c(0, 1, 1, 2))
  letfs <- lapply(seq_len(nl), function(i) {
    l <- list(base = pick(ix), leverage = pick(c(2, 3, -1, -2, 0.5, 25)))
    if (coin(0.7)) l$finance <- if ("rate" %in% aux && coin(0.6)) "rate" else round(runif(1, 0, 6), 2)
    if (coin(0.5)) l$expense <- round(runif(1, 0, 1.5), 2)
    if (coin(0.3)) l$spread <- round(runif(1, 0, 1), 2)
    if ("days" %in% aux && coin(0.5)) l$days <- "days"
    if (coin(0.2)) l$rate_basis <- 365
    l
  })
  # Konfiguration als Code
  lst <- function(x, L) {
    if (!length(x)) return(switch(L, r = "character(0)", py = "{}", jl = "NamedTuple()"))
    switch(L, r = sprintf("c(%s)", paste(sprintf("%s = %s", names(x), vapply(x, em, "", L = L)), collapse = ", ")),
           py = sprintf("{%s}", paste(sprintf("'%s': %s", names(x), vapply(x, em, "", L = L)), collapse = ", ")),
           jl = sprintf("(%s,)", paste(sprintf("%s = %s", names(x), vapply(x, em, "", L = L)), collapse = ", ")))
  }
  lt <- function(L) {
    one <- function(l) switch(L,
      r = sprintf("list(%s)", paste(sprintf("%s = %s", names(l), vapply(l, em, "", L = L)), collapse = ", ")),
      py = sprintf("{%s}", paste(sprintf("'%s': %s", names(l), vapply(l, em, "", L = L)), collapse = ", ")),
      jl = sprintf("(%s,)", paste(sprintf("%s = %s", names(l), vapply(l, em, "", L = L)), collapse = ", ")))
    body <- paste(vapply(letfs, one, ""), collapse = ", ")
    switch(L, r = sprintf("list(%s)", body), py = sprintf("[%s]", body), jl = sprintf("[%s]", body))
  }
  ixv <- setNames(ix, ix)
  cfg <- list(
    r = sprintf("cfg <- bootstrap_config(%s, letfs = %s%s%s, input = '%s')", lst(ixv, "r"), lt("r"),
                if (length(aux)) sprintf(", aux = %s", lst(aux, "r")) else "", if (length(at)) sprintf(", aux_type = %s", lst(at, "r")) else "",
                if (prices) "prices" else "returns"),
    py = sprintf("cfg = simlev.bootstrap_config(%s, letfs=%s%s%s, input='%s')", lst(ixv, "py"), lt("py"),
                 if (length(aux)) sprintf(", aux=%s", lst(aux, "py")) else "", if (length(at)) sprintf(", aux_type=%s", lst(at, "py")) else "",
                 if (prices) "prices" else "returns"),
    jl = sprintf("cfg = SL.bootstrap_config(%s, letfs = %s%s%s, input = \"%s\")", lst(ixv, "jl"), lt("jl"),
                 if (length(aux)) sprintf(", aux = %s", lst(aux, "jl")) else "", if (length(at)) sprintf(", aux_type = %s", lst(at, "jl")) else "",
                 if (prices) "prices" else "returns"))
  meth <- pick(c("raw", "block", "circular", "stationary", "stationary", "wild", "reset", "tails", "regime", "garch"))
  nobs <- n - prices
  pl <- if (meth %in% c("wild", "reset")) NULL else pick(list(NULL, 1, 5, nobs + 7))
  np_ <- pick(c(1, 3, 12))
  sd0 <- sample.int(1e6, 1)
  args <- list(r = sprintf("'%s', n = %d, seed = %d, progress = FALSE%s", meth, np_, sd0, if (is.null(pl)) "" else sprintf(", path_length = %d", pl)),
               py = sprintf("method='%s', n=%d, seed=%d, progress=False%s", meth, np_, sd0, if (is.null(pl)) "" else sprintf(", path_length=%d", pl)),
               jl = sprintf("\"%s\"; n = %d, seed = %d, progress = false%s", meth, np_, sd0, if (is.null(pl)) "" else sprintf(", path_length = %d", pl)))
  fuzz_case(sprintf("b%05d", kk),
    r = sprintf("%s\nb <- bootstrap(d, cfg, %s)\nc(b$paths, lapply(b$paths, attr, 'aux_level'), list(b$stats$attempts, b$stats$success))", cfg$r, args$r),
    py = sprintf("%s\nb = simlev.bootstrap(d, cfg, %s)\nresult = b['paths'] + [p.attrs.get('aux_level') for p in b['paths']] + [b['stats']['attempts'], b['stats']['success']]", cfg$py, args$py),
    jl = sprintf("%s\nb = SL.bootstrap(d, cfg, %s)\nresult = vcat(b[\"paths\"], [get(p.attrs, \"aux_level\", nothing) for p in b[\"paths\"]], [b[\"stats\"][\"attempts\"], b[\"stats\"][\"success\"]])", cfg$jl, args$jl),
    inputs = list(d = d))
}
ref_done(); ref_schreiben()
