# tests/werkzeuge/gleichlauf/nav_fuzz.R – Fuzz von wrapper_nav() (seit 1.5.1: Tagesschleife des NAV im Kern
# wrapper_nav_core, core/wrapper_core_impl.h; Jahr je Tag und Abgleich der Tage ohne format()/match() je Tag)
#
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek> SIMLEV_FAELLE_DIR=<ordner> Rscript tests/werkzeuge/gleichlauf/nav_fuzz.R <n> <seed>
#
# Erzeugt <n> Fälle im Format der Referenzfälle (tests/gleichlauf/erzeugen/ref_tools.R) als Modul nav_fuzz:
# wrapper_nav() mit Tages- oder Werktagsdaten (1 bis 900 Zeilen, Start auch um Jahreswechsel und 29. Februar,
# Jahre 1900 bis 2090), zwei oder drei inneren Spalten, NA-Tagen, spätem Start, unsortierten Zeilen, Kurssprüngen
# bis fast 0, Verwaltungs- und Performancegebühr (auch 0 und 100 %), Volumen, Ordergebühr, Rebalancing;
# Fehler (innerer Wert nicht definiert, Eingaben). Dazu je fünfter Fall simulation() mit einem Wrapper-Asset
# (NAV als Kursspalte). Warnungen und Fehler mit ihren Aufrufen (r_calls) wie sim_fuzz.R.
#
# Prüfung (tests/werkzeuge/gleichlauf/run.py, Schritt 5): abgelegte Referenz (seit 1.6.2 aus R 1.6.2, run.py --ref-erzeugen 162), R neu mit
# tests/werkzeuge/gleichlauf/sim_fuzz_cmp.py, Python und Julia mit vergleich.py/vergleich.jl gegen die Referenz.
source("tests/gleichlauf/erzeugen/ref_tools.R")
args <- commandArgs(TRUE)
N <- as.integer(args[1]); seed0 <- as.integer(if (length(args) >= 2) args[2] else 20261109)
ref_bereich("nav_fuzz", alle = TRUE); ref_init("nav_fuzz")
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

for (kk in seq_len(N)) {
  set.seed(seed0 + kk)
  n <- pick(c(1, 2, 3, 10, 40, 120, 250, 400, 400, 900))
  y0 <- if (coin(0.1)) pick(c(1900, 1999, 2000, 2090)) else sample(1960:2040, 1)
  start <- if (coin(0.25)) as.Date(sprintf("%d-12-%02d", y0, sample(25:31, 1)))
           else if (coin(0.1)) as.Date(sprintf("%d-02-%02d", y0 - y0 %% 4, sample(26:29, 1)))
           else as.Date(sprintf("%d-01-01", y0)) + sample(0:364, 1)
  d <- data.frame(date = seq.Date(start, by = "day", length.out = n))
  if (n > 7 && coin(0.4)) { d <- d[!format(d$date, "%u") %in% c("6", "7"), , drop = FALSE]; rownames(d) <- NULL }
  n <- nrow(d)
  nc <- pick(c(2, 2, 3))
  for (j in seq_len(nc)) {
    p <- round(runif(1, 1, 300) * cumprod(pmax(1e-4, 1 + rnorm(n, runif(1, -5e-4, 1e-3), runif(1, 0.002, 0.04)))), 4)
    if (n > 5 && coin(0.15)) { i0 <- sample(2:n, 1); p[i0:min(n, i0 + sample(0:9, 1))] <- NA }
    if (n > 5 && coin(0.1)) p[seq_len(sample(1:(n - 1), 1))] <- NA                      # später Start
    if (n > 5 && coin(0.03)) p[sample.int(n, 1)] <- pick(c(0, -1))                      # unzulässiger Kurs
    d[[LETTERS[j]]] <- p
  }
  if (n > 3 && coin(0.08)) { d <- d[sample.int(n), , drop = FALSE]; rownames(d) <- NULL }   # unsortiert
  fee <- num(pick(c(0, 0.2, 0.95, 2.5, 20, 100))); perf <- num(pick(c(0, 5, 10, 25, 100)))
  sh <- if (nc == 2) c(0.6, 0.4) else c(0.5, 0.3, 0.2)
  ex <- list(r = character(0), py = character(0), jl = character(0))
  add <- function(r, py, jl) { ex$r <<- c(ex$r, r); ex$py <<- c(ex$py, py); ex$jl <<- c(ex$jl, jl) }
  if (coin(0.3)) add("rebalance = rebalance_plan(unit = 'quarter')", "rebalance=simlev.rebalance_plan(unit='quarter')",
                     "rebalance = SL.rebalance_plan(; unit = \"quarter\")")
  if (coin(0.2)) {
    v <- num(pick(c(1, 1e6, 12345.5))); add(paste("volume =", v), paste0("volume=", v), paste("volume =", v))
    if (coin(0.4)) add("order_fee = 1", "order_fee=1", "order_fee = 1")                 # feste Ordergebühr in EUR
  }
  sr <- sprintf("%s = asset_config('etf', 'bnh', %s)", LETTERS[seq_len(nc)], sh)
  sp <- sprintf("%s=simlev.asset_config(asset_class='etf', trading='bnh', share=%s)", LETTERS[seq_len(nc)], sh)
  sj <- sprintf("\"%s\" => SL.asset_config(\"etf\", \"bnh\", %s)", LETTERS[seq_len(nc)], sh)
  cr <- sprintf("inner <- create_strategy(%s)\nwz <- wrapper_config(inner, costs = funds_costs(%s, %s)%s)",
                paste(sr, collapse = ", "), fee, perf, paste0(if (length(ex$r)) ", ", paste(ex$r, collapse = ", ")))
  cp <- sprintf("inner = simlev.create_strategy(%s)\nwz = simlev.wrapper_config(inner, costs=simlev.funds_costs(fee=%s, performance_fee=%s)%s)",
                paste(sp, collapse = ", "), fee, perf, paste0(if (length(ex$py)) ", ", paste(ex$py, collapse = ", ")))
  cj <- sprintf("inner = SL.create_strategy(%s)\nwz = SL.wrapper_config(inner; costs = SL.funds_costs(%s, %s)%s)",
                paste(sj, collapse = ", "), fee, perf, paste0(if (length(ex$jl)) ", ", paste(ex$jl, collapse = ", ")))
  inp <- list(d = d)
  if (coin(0.8)) {
    fuzz_case(sprintf("w%05d", kk), r = paste0(cr, "\nwrapper_nav(d, wz)"),
              py = paste0(cp, "\nresult = simlev.wrapper_nav(d, wz)"), jl = paste0(cj, "\nresult = SL.wrapper_nav(d, wz)"),
              inputs = inp)
  } else {
    sv <- num(pick(c(1000, 1e5)))
    fuzz_case(sprintf("s%05d", kk),
      r = paste0(cr, sprintf("\nsimulation(d, create_strategy(F = asset_config('etf', 'bnh', 1, wrapper = wz)), start_value = %s)", sv)),
      py = paste0(cp, sprintf("\nresult = simlev.simulation(d, simlev.create_strategy(F=simlev.asset_config(asset_class='etf', trading='bnh', share=1, wrapper=wz)), start_value=%s)", sv)),
      jl = paste0(cj, sprintf("\nresult = SL.simulation(d, SL.create_strategy(\"F\" => SL.asset_config(\"etf\", \"bnh\", 1; wrapper = wz)); start_value = %s)", sv)),
      inputs = inp)
  }
}
ref_done(); ref_schreiben()
