# Huellen der Optimierer der C-Bibliothek slc (SimLev core, Etappe 9.3): .sl_optim() und
# Pruefhilfen. Die Rechnung steht in src/slc_opt.c (Kopie von core/, tools/core_sync.py), die
# .Call-Huellen in src/slc_r_opt.c (Registrierung in src/init.c, in R als C_sl_*).
#
# Rueckfrage an den Host (Entwurf B.8): .sl_optim() laeuft in einer Schleife "Anfrage holen ->
# Zielfunktion in R -> Antwort geben"; der Kern ruft nie in R zurueck. Fehler der Zielfunktion
# sind daher gewoehnliche R-Fehler.
#
# Seit Etappe 9.6b sind die Aufrufer (stats::optim an sechs Stellen) umgestellt bzw. laufen ganz
# in C (GARCH, DCC, MS-GARCH); .sl_optim() nimmt dafuer die Argumente und Steuerwerte von stats::optim an, soweit
# SimLev sie nutzt, und gibt eine Liste wie optim zurueck.

# Verfahren: Namen wie optim und eigene
.sl_opt_methods <- c("Nelder-Mead" = 3L, "BFGS" = 1L, "L-BFGS-B" = 2L, "PBFGS" = 2L, "NM" = 3L)

# Steuerwerte (Liste wie optim$control) in die Werte des Kerns uebersetzen.
#   Nelder-Mead: maxit begrenzt wie bei optim die Funktionsauswertungen (Standard 500);
#                maxfev ist ein Synonym; die Zahl der Iterationen ist nicht begrenzt.
#   BFGS:        maxit Iterationen (Standard 100), maxfev Funktionsauswertungen (Standard ohne).
#   L-BFGS-B / PBFGS: wie BFGS; factr = Vielfaches von eps fuer die relative Abnahme
#                (reltol = factr * eps, Standard factr = 1e7 wie optim), pgtol = gtol.
#   reltol (Standard sqrt(eps)), gtol (Standard 1e-8), xtol (Standard eps), fnscale, parscale.
#   trace = TRUE: Mitschrift aller Auswertungen im Ergebnis (Feld trace).
.sl_opt_control <- function(control, m, n) {
  known <- c("maxit", "maxfev", "reltol", "factr", "pgtol", "gtol", "xtol", "fnscale", "parscale", "trace")
  if (!is.list(control)) stop("optim: control muss eine Liste sein", call. = FALSE)
  bad <- setdiff(names(control), known)
  if (length(bad)) stop(sprintf("optim: unbekannte Steuerwerte %s", paste0("'", bad, "'", collapse = ", ")), call. = FALSE)
  num1 <- function(k, def) {
    v <- control[[k]]
    if (is.null(v)) return(def)
    if (!is.numeric(v) || length(v) != 1L || is.na(v)) stop(sprintf("optim: Steuerwert %s muss eine Zahl sein", k), call. = FALSE)
    as.double(v)
  }
  eps <- .Machine$double.eps
  if (!is.null(control$factr) && !is.null(control$reltol))
    stop("optim: factr und reltol nicht zugleich angeben", call. = FALSE)
  if (m == 3L) {
    maxfev <- num1("maxfev", num1("maxit", 500))
    maxit <- 0
    reltol <- num1("reltol", sqrt(eps))
  } else {
    maxit <- num1("maxit", 100)
    maxfev <- num1("maxfev", 0)
    reltol <- if (!is.null(control$factr)) num1("factr", 1e7) * eps
              else num1("reltol", if (m == 2L) 1e7 * eps else sqrt(eps))
  }
  gtol <- num1("gtol", num1("pgtol", 1e-8))
  ctrl <- c(maxit, maxfev, reltol, gtol, num1("xtol", eps), num1("fnscale", 1))
  ps <- control$parscale
  if (!is.null(ps)) {
    if (!is.numeric(ps) || !(length(ps) %in% c(1L, n))) stop("optim: Steuerwert parscale passt nicht zu par", call. = FALSE)
    ps <- rep_len(as.double(ps), n)
  }
  list(ctrl = ctrl, parscale = ps, trace = isTRUE(control$trace))
}

#' Minimieren mit den Optimierern der C-Bibliothek slc
#'
#' Wie stats::optim fuer die Verfahren "Nelder-Mead", "BFGS" und "L-BFGS-B" (hier projizierter
#' BFGS nach Bertsekas 1982, auch "PBFGS"); Ergebnis list(par, value, counts, convergence,
#' message, iterations, evaluations[, trace]).
#' @keywords internal
#' @noRd
.sl_optim <- function(par, fn, gr = NULL, ..., method = c("Nelder-Mead", "BFGS", "L-BFGS-B", "PBFGS", "NM"),
                      lower = -Inf, upper = Inf, control = list()) {
  method <- match.arg(method)
  m <- .sl_opt_methods[[method]]
  if (!is.numeric(par) || !length(par)) stop("optim: par muss ein nichtleerer Zahlenvektor sein", call. = FALSE)
  nms <- names(par)
  x0 <- as.double(par)
  n <- length(x0)
  fn1 <- function(x) fn(x, ...)
  gr1 <- if (is.null(gr)) NULL else function(x) gr(x, ...)
  ct <- .sl_opt_control(control, m, n)
  lo <- hi <- NULL
  if (m == 2L) {
    lo <- rep_len(as.double(lower), n); hi <- rep_len(as.double(upper), n)
  } else if (any(is.finite(lower)) || any(is.finite(upper))) {
    stop(sprintf("optim: Schranken nur mit L-BFGS-B bzw. PBFGS (nicht %s)", method), call. = FALSE)
  }
  ws <- .Call(C_sl_opt_init, m, x0, lo, hi, ct$ctrl, ct$parscale, as.integer(!is.null(gr1)))
  tr_x <- list(); tr_f <- numeric(0); tr_k <- integer(0)
  q <- .Call(C_sl_opt_next, ws, NULL)
  while (!is.null(q)) {
    x <- q[[2L]]; names(x) <- nms
    if (q[[1L]] == 1L) {
      v <- fn1(x)
      if (length(v) != 1L || !(is.numeric(v) || is.logical(v)))
        stop(sprintf("optim: die Zielfunktion muss eine Zahl liefern (erhalten: L\u00e4nge %d)", length(v)), call. = FALSE)
      v <- as.double(v)
      if (ct$trace) { tr_x[[length(tr_x) + 1L]] <- q[[2L]]; tr_f <- c(tr_f, v); tr_k <- c(tr_k, 1L) }
    } else {
      v <- gr1(x)
      if (!is.numeric(v) || length(v) != n)
        stop(sprintf("optim: der Gradient muss %d Zahlen liefern (erhalten: L\u00e4nge %d)", n, length(v)), call. = FALSE)
      v <- as.double(v)
      if (ct$trace) { tr_x[[length(tr_x) + 1L]] <- q[[2L]]; tr_f <- c(tr_f, NaN); tr_k <- c(tr_k, 2L) }
    }
    q <- .Call(C_sl_opt_next, ws, v)
  }
  r <- .Call(C_sl_opt_result, ws)
  p <- r$par; names(p) <- nms
  out <- list(par = p, value = r$value,
              counts = c(`function` = r$nfev, gradient = if (m == 3L) NA_integer_ else r$ngev),
              convergence = r$convergence, message = r$message, iterations = r$iterations,
              evaluations = r$evaluations)
  if (ct$trace)
    out$trace <- list(x = if (length(tr_x)) do.call(rbind, tr_x) else matrix(numeric(0), 0L, n), f = tr_f, need = tr_k)
  out
}

# ── Pruefhilfen (Plausibilitaet, Gleichlauf): Prueffunktionen in C ───────────

# Wert (grad = FALSE) bzw. list(Wert, Gradient) der Prueffunktion id an x
.sl_opt_testfn <- function(id, x, grad = FALSE)
  .Call(C_sl_opt_testfn, as.integer(id), as.double(x), as.integer(isTRUE(grad)))

# direkter C-Weg (sl_minimize) mit Prueffunktion id; Steuerwerte wie .sl_optim
.sl_minimize_test <- function(id, par, method = c("Nelder-Mead", "BFGS", "L-BFGS-B", "PBFGS", "NM"),
                              lower = -Inf, upper = Inf, control = list(), grad = FALSE) {
  method <- match.arg(method)
  m <- .sl_opt_methods[[method]]
  x0 <- as.double(par); n <- length(x0)
  ct <- .sl_opt_control(control, m, n)
  lo <- hi <- NULL
  if (m == 2L) { lo <- rep_len(as.double(lower), n); hi <- rep_len(as.double(upper), n) }
  r <- .Call(C_sl_opt_minimize_test, as.integer(id), m, x0, lo, hi, ct$ctrl, ct$parscale, as.integer(isTRUE(grad)))
  r[c("par", "value", "convergence", "iterations", "nfev", "evaluations")]
}

# numerischer Gradient (B.9) der Prueffunktion id an x (Schranken wahlweise)
.sl_numgrad_test <- function(id, x, lower = NULL, upper = NULL) {
  n <- length(x)
  .Call(C_sl_numgrad_test, as.integer(id), as.double(x),
        if (is.null(lower)) NULL else rep_len(as.double(lower), n),
        if (is.null(upper)) NULL else rep_len(as.double(upper), n))
}
