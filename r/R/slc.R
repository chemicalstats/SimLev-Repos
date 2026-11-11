# Huellen der C-Bibliothek slc (SimLev core): Zufallszustand, simlev_seed(),
# interne Ziehungen und Verteilungen .sl_*.
#
# Die Rechnung steht in src/slc*.cpp (Kopien von core/, core/sync.py), die .Call-Huellen in
# src/slc_r.cpp (Registrierung in src/init.cpp, in R als C_sl_*). Kein Code hier ruft R's
# Zufallszahlen auf; set.seed() und .Random.seed wirken auf diese Funktionen nicht.
#
# Zufallszustand:
#   - globaler Zustand G: .sl_state$rng (raw(32), Host-Bytereihenfolge von uint64_t[4]);
#     beim Laden des Pakets und mit simlev_seed(NULL) aus Uhrzeit, Prozessnummer und Zaehler;
#   - Strom-Objekt: Umgebung mit Feld state (raw(32)); die Huellen geben den neuen Zustand zurueck,
#     R ersetzt ihn (kein Aendern an Ort und Stelle);
#   - innerhalb einer parallelen Einheit (.sl_in_unit) darf G nicht benutzt werden.
#
# Seit 1.0.0 ziehen alle zufaelligen Exporte hierueber: seed = NULL zieht
# genau einmal k = .sl_next_seed() aus G und verfaehrt dann wie mit seed = k (.sl_resolve_seed);
# seed = s laesst G unberuehrt, der Hauptstrom ist .sl_stream(s); Einheiten mit cores bekommen
# ihre Stroeme U_i = J^i(S_0) aus .sl_streams() vor der Verteilung.

.sl_state <- new.env(parent = emptyenv())
.sl_state$rng <- NULL
.sl_state$counter <- 0
.sl_state$in_unit <- FALSE

# neuer Zustand aus Uhrzeit (ns), Prozessnummer und Zaehler (nicht reproduzierbar)
.sl_entropy_state <- function() {
  .sl_state$counter <- .sl_state$counter + 1
  .Call(C_sl_rng_seed_entropy, as.numeric(Sys.time()) * 1e9, as.numeric(Sys.getpid()),
        as.numeric(.sl_state$counter))
}

.onLoad <- function(libname, pkgname) {
  .sl_state$rng <- .sl_entropy_state()
  invisible(NULL)
}

# Seed pruefen: ganze Zahl mit |seed| < 2^53 (kein Faktor); liefert double. Seit 1.6.4 ohne Eingabewert in der
# Meldung (Entscheidung 8, Befund C-096; bis 1.6.3 "(erhalten: <Wert>)" in der Darstellung der Sprache); seit K43 T1-R5
# mit dem Namen fn der Funktion (Baustein ut1.seed; bis dahin "seed: ganze Zahl erwartet")
.sl_check_seed <- function(seed, fn = "simlev_seed") {
  ok <- is.numeric(seed) && !is.factor(seed) && length(seed) == 1L && !is.na(seed) && is.finite(seed) &&
    seed == trunc(seed) && abs(seed) < 2^53
  if (!ok) chk_stop("ut1.seed", fn)
  as.double(seed)
}

#' Zufallszustand von SimLev setzen
#'
#' Setzt den globalen Zufallszustand der C-Bibliothek von SimLev. Mit einer ganzen Zahl
#' entsteht ein reproduzierbarer Zustand; ohne Argument (oder mit `NULL`) ein neuer Zustand
#' aus Uhrzeit, Prozessnummer und einem Zähler, der nicht reproduzierbar ist (wie R ohne
#' `set.seed()`). Beim Laden des Pakets geschieht dasselbe.
#'
#' Der Zufallszustand von SimLev ist unabhängig von `set.seed()` und `.Random.seed`; er
#' wird in R, Python und Julia gleich gesetzt und liefert dort bei gleichem `seed` und
#' gleicher Aufruffolge bitgleiche Ziehungen. Generator ist xoshiro256** (Blackman, Vigna
#' 2021) mit SplitMix64-Seeding (Steele, Lea, Flood 2014); unabhängige Ströme je Einheit
#' entstehen durch Sprünge um 2^128 Schritte.
#'
#' Die zufälligen Funktionen von SimLev (Argument `seed`, z. B. [bootstrap()],
#' [bootstrap_study()], [scenario_copula()], [regime_hmm()]) ziehen aus diesem Zustand:
#' \itemize{
#'   \item Mit `seed = NULL` zieht ein Aufruf **genau einmal** einen Startwert k aus dem
#'     globalen Zustand (ganze Zahl von 0 bis \eqn{2^{31} - 1}) und rechnet dann wie mit
#'     `seed = k`. [bootstrap()] und [bootstrap_study()] legen k unter `$seed` ab; damit lässt
#'     sich das Ergebnis wiederholen. Nach `simlev_seed(s)` ist daher auch eine Folge von
#'     Aufrufen mit `seed = NULL` reproduzierbar.
#'   \item Mit `seed = s` bleibt der globale Zustand unberührt.
#'   \item Funktionen mit `cores` geben jedem Pfad einen eigenen Strom (Sprung um
#'     \eqn{2^{128}} je Pfad); das Ergebnis hängt nicht von `cores` oder `chunk_size` ab.
#'   \item `set.seed()`, `RNGkind()` und `.Random.seed` wirken auf SimLev nicht; SimLev liest,
#'     setzt und löscht `.Random.seed` nie.
#' }
#'
#' @param seed ganze Zahl mit \eqn{|seed| < 2^{53}} oder `NULL` (neuer, nicht
#'   reproduzierbarer Zustand).
#' @return `seed`, unsichtbar.
#' @references
#' Blackman, D., Vigna, S. (2021). Scrambled linear pseudorandom number generators. *ACM
#' Transactions on Mathematical Software* 47(4), Art. 36.
#'
#' Steele, G. L., Lea, D., Flood, C. H. (2014). Fast splittable pseudorandom number
#' generators. *Proceedings OOPSLA 2014*, 453–472.
#' @seealso [bootstrap()], [bootstrap_study()], [scenario_copula()], [regime_hmm()]
#' @examples
#' simlev_seed(42)   # reproduzierbarer Zustand
#' x <- c(0.010, -0.020, 0.015, 0.003, -0.007, 0.012, -0.004, 0.009, 0.002, -0.011, 0.006, 0.001)
#' y <- c(0.004, -0.006, 0.011, -0.002, 0.001, 0.008, -0.009, 0.005, 0.003, -0.004, 0.002, 0.000)
#' s1 <- sharpe_test(x, y, method = "bootstrap", B = 50)   # seed = NULL: ein Zug aus dem Zustand
#' simlev_seed(42)
#' s2 <- sharpe_test(x, y, method = "bootstrap", B = 50)
#' identical(s1, s2)   # TRUE: dieselbe Aufruffolge nach demselben simlev_seed()
#' set.seed(1)         # wirkt auf SimLev nicht
#' simlev_seed()       # neuer Zustand aus Uhrzeit, Prozessnummer und Zähler
#' @export
simlev_seed <- function(seed = NULL) {
  if (is.null(seed)) .sl_state$rng <- .sl_entropy_state()
  else .sl_state$rng <- .Call(C_sl_rng_seed, .sl_check_seed(seed))
  invisible(seed)
}

# ── Zustand, Stroeme ─────────────────────────────────────────────

# G benutzen (nie innerhalb einer parallelen Einheit)
.sl_global_check <- function() {
  if (isTRUE(.sl_state$in_unit))
    stop("interner Fehler: globaler Zufallszustand in paralleler Einheit", call. = FALSE)
  if (is.null(.sl_state$rng)) .sl_state$rng <- .sl_entropy_state()
  invisible(TRUE)
}

# expr als parallele Einheit auswerten (G gesperrt)
.sl_in_unit <- function(expr) {
  old <- .sl_state$in_unit
  .sl_state$in_unit <- TRUE
  on.exit(.sl_state$in_unit <- old, add = TRUE)
  expr
}

# Strom aus einem Seed bzw. Zustand
.sl_stream <- function(seed) {
  s <- new.env(parent = emptyenv())
  s$state <- .Call(C_sl_rng_seed, .sl_check_seed(seed))
  s
}

.sl_stream_from_state <- function(state) {
  s <- new.env(parent = emptyenv())
  s$state <- state
  s
}

# naechster Startwert aus G (0 ... 2^31 - 1, integer); G rueckt um eine Ausgabe vor
.sl_next_seed <- function() {
  .sl_global_check()
  res <- .Call(C_sl_rng_seed31, .sl_state$rng)
  .sl_state$rng <- res[[2L]]
  res[[1L]]
}

# seed = NULL -> .sl_next_seed(), sonst geprueft (G bleibt unberuehrt)
.sl_resolve_seed <- function(seed, fn = "simlev_seed") if (is.null(seed)) .sl_next_seed() else .sl_check_seed(seed, fn)

# Hauptstrom einer zufaelligen Funktion: S := Seeding(k bzw. s); fn fuer die Meldung eines ungueltigen seed
.sl_main_stream <- function(seed, fn = "simlev_seed") .sl_stream(.sl_resolve_seed(seed, fn))

# Stroeme je Einheit U_i = J^i(S_0), i = 1 ... n (Liste von Stroemen)
.sl_streams <- function(stream, n) {
  st <- if (is.environment(stream)) stream$state else .Call(C_sl_rng_seed, .sl_check_seed(stream))
  lapply(.Call(C_sl_rng_streams, st, as.double(n)), .sl_stream_from_state)
}

# Zustand als 4 Hex-Woerter (Gleichlauf, Pruefung)
.sl_state_hex <- function(stream = NULL) {
  if (is.null(stream)) { .sl_global_check(); .Call(C_sl_rng_hex, .sl_state$rng) }
  else .Call(C_sl_rng_hex, stream$state)
}

# Ziehung ausfuehren und Zustand ersetzen
.sl_draw <- function(fun, stream, ...) {
  if (is.null(stream)) {
    .sl_global_check()
    res <- .Call(fun, .sl_state$rng, ...)
    .sl_state$rng <- res[[2L]]
  } else {
    res <- .Call(fun, stream$state, ...)
    stream$state <- res[[2L]]
  }
  res[[1L]]
}

# rohe 64-Bit-Ausgaben als Hex (Testvektoren)
.sl_u64 <- function(n, stream = NULL) .sl_draw(C_sl_rng_u64, stream, as.double(n))

# ── Ziehungen (n = Anzahl) ───────────────────────────────────────────────────

.sl_runif <- function(n, min = 0, max = 1, stream = NULL)
  .sl_draw(C_sl_runif, stream, as.double(n), as.double(min), as.double(max))

.sl_rnorm <- function(n, mean = 0, sd = 1, stream = NULL)
  .sl_draw(C_sl_rnorm, stream, as.double(n), as.double(mean), as.double(sd))

.sl_rexp <- function(n, rate = 1, stream = NULL)
  .sl_draw(C_sl_rexp, stream, as.double(n), as.double(rate))

.sl_rgeom <- function(n, prob, stream = NULL)
  .sl_draw(C_sl_rgeom, stream, as.double(n), as.double(prob))

.sl_rgamma <- function(n, shape, scale = 1, stream = NULL)
  .sl_draw(C_sl_rgamma, stream, as.double(n), as.double(shape), as.double(scale))

.sl_rchisq <- function(n, df, stream = NULL)
  .sl_draw(C_sl_rchisq, stream, as.double(n), as.double(df))

# Stichprobe aus 1 ... n (wie sample.int); Ergebnis integer
.sl_sample <- function(n, size = n, replace = FALSE, prob = NULL, stream = NULL)
  .sl_draw(C_sl_sample, stream, as.double(n), as.double(size), as.logical(replace),
           if (is.null(prob)) NULL else as.double(prob))

# ── Verteilungen (Parameter skalar; Attribute von x bleiben wie bei pnorm usw.) ──

.sl_attr <- function(x, out) {
  a <- attributes(x)
  if (!is.null(a)) attributes(out) <- a
  out
}

.sl_pnorm <- function(q, mean = 0, sd = 1, lower.tail = TRUE)
  .sl_attr(q, .Call(C_sl_pnorm, as.double(q), as.double(mean), as.double(sd), as.logical(lower.tail)))

.sl_qnorm <- function(p, mean = 0, sd = 1, lower.tail = TRUE)
  .sl_attr(p, .Call(C_sl_qnorm, as.double(p), as.double(mean), as.double(sd), as.logical(lower.tail)))

.sl_dnorm <- function(x, mean = 0, sd = 1, log = FALSE)
  .sl_attr(x, .Call(C_sl_dnorm, as.double(x), as.double(mean), as.double(sd), as.logical(log)))

.sl_erfc <- function(x) .sl_attr(x, .Call(C_sl_erfc, as.double(x)))

.sl_lgamma <- function(x) .sl_attr(x, .Call(C_sl_lgamma, as.double(x)))

.sl_pbeta <- function(q, shape1, shape2, lower.tail = TRUE)
  .sl_attr(q, .Call(C_sl_pbeta, as.double(q), as.double(shape1), as.double(shape2), as.logical(lower.tail)))

# pt/qt seit 1.6.0 elementweise auf mehreren Threads (Kern sl_pt_mt/sl_qt_mt, Ergebnis unabhaengig davon)
.sl_pt <- function(q, df, lower.tail = TRUE)
  .sl_attr(q, .Call(C_sl_pt_mt, as.double(q), as.double(df), as.logical(lower.tail), .sl_nthreads()))

.sl_qt <- function(p, df, lower.tail = TRUE)
  .sl_attr(p, .Call(C_sl_qt_mt, as.double(p), as.double(df), as.logical(lower.tail), .sl_nthreads()))

# Hoechstwert fuer Parallelitaet (seit 1.6.4, Entscheidung 41b; cores und Kern-Threads): Zahl der Prozessoren,
# mindestens 1, aus dem Kern (sl_nprocs, core/slc_prep.cpp; eine Quelle fuer R, Python und Julia)
.sl_nprocs <- function() .Call(C_sl_nprocs)

# Threads der elementweisen Kerne (seit 1.6.0): Umgebungsvariable SIMLEV_THREADS (ASCII-Ziffern, >= 1), sonst 0 =
# Hoechstwert (Zahl der Prozessoren; bis 1.6.3 hoechstens 8). Seit 1.6.4 (Entscheidung 41b) wird mehr als der
# Hoechstwert mit einem Hinweis (einmal je Sitzung) begrenzt; wie python/simlev/_lib.py und julia/src/slib.jl.
# Seit 1.6.4 (Entscheidung 41c) zusaetzlich je parallele Einheit hoechstens .sl_state$thread_cap Threads (von
# .par_lapply gesetzt: Zahl der Prozessoren / Zahl der gleichzeitigen Einheiten, mindestens 1), auch bei gesetztem
# SIMLEV_THREADS (ohne Hinweis).
.sl_nthreads <- function() {
  v <- .sl_env_threads()
  if (v >= 1L) {
    mx <- .sl_nprocs()
    if (v > mx) {
      if (!isTRUE(.sl_state$threads_hint)) {
        assign("threads_hint", TRUE, envir = .sl_state)
        message(chk_msg("hinweis.prozessoren", "SIMLEV_THREADS", mx))
      }
      v <- mx
    }
  }
  cap <- .sl_state$thread_cap
  if (!is.null(cap)) v <- if (v == 0L) cap else min(v, cap)
  v
}

# SIMLEV_THREADS als ganze Zahl >= 1, sonst 0 (ohne Begrenzung und Hinweis; seit 1.6.4 nur ASCII-Ziffern,
# Entscheidungen 27, 65; "2.7", "0x10", "+3" wie andere Fehlwerte: 0)
.sl_env_threads <- function() {
  v <- trimws(Sys.getenv("SIMLEV_THREADS", ""), whitespace = "[ \t\r\n]")
  v <- if (grepl("^[0-9]+$", v)) suppressWarnings(as.integer(v)) else NA_integer_
  if (is.na(v) || v < 1L) 0L else v
}

# Kern-Threads ausserhalb paralleler Einheiten als Zahl >= 1 (cores = "auto" fuer die Starts des MS-GARCH-Fits, seit
# 1.6.4): .sl_nthreads(), 0 = Zahl der Prozessoren
.sl_auto_threads <- function() {
  v <- .sl_nthreads()
  if (v == 0L) .sl_nprocs() else v
}

# Planer fuer cores = "auto" (seit 1.6.4, Kern sl_par_plan in core/slc_prep.cpp; gleiche Regel in Python und Julia):
# c(Laeufe, Kern-Threads je Lauf) fuer n weitere Einheiten mit Rechenzeit unit_s (Sekunden) und Ergebnisgroesse
# unit_bytes je Einheit. sys 0 = R (Fork). nprocs, mem, self, running und env lassen sich fuer Proben der Regel vorgeben
# (Testschalter fuer andere Rechnergroessen und Fremdlast, nicht oeffentlich); sonst Zahl der Prozessoren, freier
# Speicher laut System, Speicher des eigenen Prozesses, laufende Prozesse (Entscheidung 112) und SIMLEV_THREADS.
.sl_par_plan <- function(n, unit_s, unit_bytes = 0, sys = 0L, nprocs = .sl_nprocs(), max_runs = nprocs,
                         env = .sl_env_threads(), mem = .sl_mem_avail(), self = .sl_mem_self(),
                         running = .sl_load_running())
  .Call(C_sl_par_plan, as.integer(sys), as.integer(nprocs), as.integer(max_runs), as.integer(env), as.double(n),
        as.double(unit_s), as.double(unit_bytes), as.double(mem), as.double(self), as.double(running))

# laufende Prozesse laut System einschliesslich des eigenen (-1 unbekannt; Kern sl_load_running, Entscheidung 112)
.sl_load_running <- function() .Call(C_sl_load_running)

# freier Arbeitsspeicher bzw. Speicher des eigenen Prozesses in Bytes laut System (-1 unbekannt; Kern sl_mem_avail,
# sl_mem_self)
.sl_mem_avail <- function() .Call(C_sl_mem_avail)
.sl_mem_self <- function() .Call(C_sl_mem_self)

# Messzeit vor dem Plan (Kern sl_par_probe): Start eines weiteren Laufs des Systems sys in Sekunden
.sl_par_probe <- function(sys = 0L, self = .sl_mem_self()) .Call(C_sl_par_probe, as.integer(sys), as.double(self))

# Threads je Einheit bei w gleichzeitigen Einheiten (seit 1.6.4, Entscheidung 41c): Zahl der Prozessoren %/% w,
# mindestens 1; die Gesamtzahl der Rechenstraenge bleibt damit hoechstens bei der Zahl der Prozessoren
.sl_unit_threads <- function(w) max(1L, .sl_nprocs() %/% as.integer(w))

.sl_plogis <- function(q) .sl_attr(q, .Call(C_sl_plogis, as.double(q)))

.sl_qlogis <- function(p) .sl_attr(p, .Call(C_sl_qlogis, as.double(p)))

.sl_version <- function() .Call(C_sl_version)
