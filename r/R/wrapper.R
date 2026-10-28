# =============================================================================
# Fonds-Wrapper (Etappe 6.5c, Ansatz C): Anteilswert (NAV) aus einer inneren Strategie
# =============================================================================
#
#   wrapper_config(strategy, rebalance, costs, order_fee, volume)  -> SimLevWrapperConfig
#   asset_config(..., wrapper = wrapper_config(...))                Wrapper als ein Asset der Strategie
#   wrapper_nav(data, wrapper, splits)                              -> SimLevWrapperNav (date, nav, ...)
#
# simulation() rechnet je Wrapper-Asset den Anteilswert (.wrapper_nav_calc) und haengt ihn als Kursspalte
# mit dem Asset-Namen an data an (.sim_check_inputs, nach der Pruefung der Datumsspalte). Danach rechnet die
# Engine mit einem gewoehnlichen asset_config ohne wrapper; Steuern, Spread, Order- und Sparplangebuehren gelten
# fuer den Wrapper wie fuer jedes Einzelpapier. Fuer die NAV-Spalte selbst gibt es keine Splits.
#
# Rechenregeln des Anteilswerts (fuer die Ports woertlich; Reihenfolge der Operationen wie hier):
#   1. Innere Bruttorechnung: simulation(d, strategy, start_value = S, costs = sim_costs(order_fee = order_fee),
#      rebalance = rebalance, splits = splits, tax = NULL, fractions = TRUE) mit S = volume, ohne volume S = 100.
#      d = data ab der ersten Zeile (nach Datum), in der mindestens eine innere Kursspalte nicht NA ist.
#      G = result$worth an den NAV-Tagen; NAV-Tage = Datenzeilen von d, die in result$filled nicht als
#      aufgefuellt gelten (Zeilen, in denen alle inneren Kurse NA sind, haben keinen Anteilswert: NA).
#   2. Start: U = 100, H = 100, G_prev = S, d_prev = erster Tag von d (Start der inneren Rechnung).
#   3. Je NAV-Tag t (aufsteigend), y = Kalenderjahr von t, D = 366 im Schaltjahr, sonst 365,
#      dd = Kalendertage von d_prev bis t (am ersten NAV-Tag in der Regel 0):
#        a      = U * (G_t / G_prev)                      Wert je Anteil vor Kosten
#        k      = fee / 100 * dd / D                       (von links nach rechts: ((fee / 100) * dd) / D)
#        fee_t  = a * k                                    Verwaltungsgebuehr des Tages je Anteil
#        U      = a - fee_t
#        acc_t  = performance_fee / 100 * max(0, U - H)    abgegrenzte Performancegebuehr (High-Water-Mark H)
#        nav_t  = U - acc_t
#        Festschreibung, wenn t der letzte NAV-Tag seines Kalenderjahres ist und nicht der letzte NAV-Tag
#        insgesamt: paid_t = acc_t; U = nav_t; H = max(H, U). Sonst paid_t = 0.
#        gross_t = 100 * G_t / S; hwm_t = H (nach der Festschreibung); G_prev = G_t; d_prev = t.
#      Ist G_prev <= 0 oder G_t nicht endlich und > 0, bricht die Rechnung mit Fehler ab (kommt ohne
#      Entnahmen und Steuern nicht vor: Kurse sind positiv, Gebuehren uebersteigen nie den Orderwert).
#   Naeherung: Die Kosten werden auf die Bruttorechnung angewandt; feste Ordergebuehren beziehen sich damit auf
#   das Volumen ohne abgezogene Fondskosten. Einzahlungen der Anleger aendern das Fondsvolumen nicht (E9).
#   Mit einer Ordergebuehr beim Start ist schon der erste Anteilswert 100 * G_1 / S < 100 (ebenso mit innerem
#   Spread > 0): Das ist U_0 = 100 vor dem ersten Tag und G_0 = S.

# ── Hilfen ────────────────────────────────────────────────────────────────────

#' Kursspalten einer Strategie
#'
#' Zweck: die Datenspalten, die eine Strategie als Kurse braucht: je Asset sein Name, fuer Wrapper-Assets
#' (asset_config(wrapper = )) die Spalten der inneren Strategie. Reihenfolge wie in der Strategie, ohne
#' Doppelte. Fuer Strategien ohne Wrapper gleich names(strategy).
#' @keywords internal
#' @noRd
.strategy_columns <- function(strategy) {
  cols <- character(0)
  for (nm in names(strategy)) {
    w <- if (is.list(strategy[[nm]])) strategy[[nm]][["wrapper"]] else NULL
    cols <- c(cols, if (inherits(w, "SimLevWrapperConfig")) .strategy_columns(w$strategy) else nm)
  }
  unique(cols)
}

# Namen der Wrapper-Assets einer Strategie
.strategy_wrappers <- function(strategy)
  names(strategy)[vapply(strategy, function(a) is.list(a) && !is.null(a[["wrapper"]]), TRUE)]

.wrapper_is_leap <- function(y) (y %% 4L == 0L & y %% 100L != 0L) | y %% 400L == 0L

# ── wrapper_config ────────────────────────────────────────────────────────────

#' Fonds-Wrapper konfigurieren
#' @export
#' @noRd
wrapper_config <- function(strategy, rebalance = NULL, costs = funds_costs(), order_fee = NULL, volume = NULL) {
  who <- "wrapper_config"
  if (missing(strategy) || is.null(strategy))
    stop("wrapper_config: strategy fehlt (innere Strategie aus create_strategy() oder eine Liste, die create_strategy() annimmt).",
         call. = FALSE)
  if (!inherits(strategy, "strategy")) {
    if (!is.list(strategy))
      stop(sprintf("wrapper_config: strategy muss ein Objekt aus create_strategy() oder eine benannte Liste von Asset-Konfigurationen sein, nicht %s.",
                   class(strategy)[1]), call. = FALSE)
    strategy <- create_strategy(assets = strategy)
  }
  strategy_validate(strategy)
  nested <- .strategy_wrappers(strategy)
  if (length(nested))
    stop(sprintf("wrapper_config: Asset '%s' der inneren Strategie hat selbst einen Wrapper; verschachtelte Wrapper sind nicht m\u00f6glich.",
                 nested[1]), call. = FALSE)
  total <- sum(vapply(strategy, function(a) a$share, numeric(1)))
  if (abs(total - 1) > 1e-6)
    stop(sprintf("wrapper_config: Gewichte (share) der inneren Strategie summieren sich auf %.4f, m\u00fcssen aber 1 ergeben.", total),
         call. = FALSE)
  if (!is.null(rebalance) && !inherits(rebalance, "SimLevRebalancePlan"))
    stop(sprintf("wrapper_config: rebalance muss NULL oder ein Objekt aus rebalance_plan() sein, nicht %s.",
                 paste(class(rebalance), collapse = "/")), call. = FALSE)
  if (!inherits(costs, "SimLevFundsCosts"))
    stop(sprintf("wrapper_config: costs muss ein Objekt aus funds_costs() sein, nicht %s.",
                 if (is.null(costs)) "NULL" else paste(class(costs), collapse = "/")), call. = FALSE)
  fs <- .fee_spec(order_fee)
  if (!is.null(volume) && (!is.numeric(volume) || length(volume) != 1L || !is.finite(volume) || volume <= 0))
    stop(sprintf("wrapper_config: 'volume' muss NULL oder eine einzelne endliche Zahl > 0 sein (Fondsvolumen in EUR), nicht %s.",
                 .blk_show(volume)), call. = FALSE)
  if (!is.null(fs) && is.null(volume) && (fs$fixed > 0 || fs$min > 0 || is.finite(fs$max)))
    stop(paste0("wrapper_config: order_fee enth\u00e4lt feste Betr\u00e4ge in EUR (fixed, min oder max); daf\u00fcr ist das Fondsvolumen ",
                "'volume' in EUR n\u00f6tig (die innere Rechnung startet dann mit diesem Volumen). Ohne volume gehen nur ",
                "Prozentgeb\u00fchren (order_fee = list(percent = ...))."), call. = FALSE)
  spr <- vapply(strategy, function(a) a$spread %||% 0, numeric(1))
  if (any(spr > 0))
    message(sprintf("Hinweis: wrapper_config: innere Assets mit Spread > 0: %s; der Spread gilt in der inneren Rechnung (Kauf und Umschichten).",
                    paste(sprintf("'%s' (%s %%)", names(spr)[spr > 0], vapply(spr[spr > 0], .blk_fmt, "")), collapse = ", ")))
  structure(list(strategy = strategy, rebalance = rebalance, costs = costs, order_fee = order_fee, volume = volume),
            class = "SimLevWrapperConfig")
}

.wrapper_assets_text <- function(strategy)
  paste(sprintf("%s %s %%", names(strategy), vapply(strategy, function(a) .blk_fmt(100 * a$share), "")), collapse = ", ")

#' @export
#' @noRd
print.SimLevWrapperConfig <- function(x, ...) {
  rb <- x$rebalance
  .blk_print("Fonds-Wrapper (wrapper_config)",
             list("Innere Assets" = .wrapper_assets_text(x$strategy),
                  "Umschichten" = if (is.null(rb)) "keines"
                                  else if (!is.null(rb$event_col) && identical(rb$event_mode, "replace")) sprintf("an Ereignissen (Spalte '%s')", rb$event_col)
                                  else .blk_sched_text(rb$span, rb$unit, rb$days, rb$anchor),
                  "Fondskosten" = sprintf("%s %% p. a. (t\u00e4glich je Kalendertag)", .blk_fmt(x$costs$fee)),
                  "Performancegeb\u00fchr" = sprintf("%s %% \u00fcber dem H\u00f6chststand (t\u00e4glich abgegrenzt, j\u00e4hrlich festgeschrieben)",
                                                    .blk_fmt(x$costs$performance_fee)),
                  "Ordergeb\u00fchr innen" = .blk_fee_text(x$order_fee),
                  "Fondsvolumen" = if (is.null(x$volume)) "nicht angegeben (Start mit 100)"
                                   else sprintf("%.2f EUR", x$volume)))
  invisible(x)
}

# ── Anteilswert ───────────────────────────────────────────────────────────────

#' Anteilswert eines Wrappers rechnen (intern)
#'
#' Zweck: die Rechenregeln aus dem Dateikopf. data: data.frame mit Spalte date (Date, aufsteigend, ohne
#' Doppelte) und den inneren Kursspalten; ein Attribut 'filled' (Matrix wie aus series_align()) geht an die
#' innere Rechnung. splits: NULL oder SimLevSplitRule (fuer die inneren Spalten). tag/who: Kennung fuer
#' Meldungen bzw. Warnungen und Fehler. Meldungen der inneren Rechnung erscheinen als
#' "Hinweis: <tag> (innere Rechnung): ...", Warnungen und Fehler als "<who> (innere Rechnung): ...".
#' Paketzustand .fee_env wird gesichert und (auch bei Fehlern) wiederhergestellt.
#' Ausgabe: SimLevWrapperNav.
#' @keywords internal
#' @noRd
.wrapper_nav_calc <- function(data, wrapper, splits, tag, who) {
  st <- wrapper$strategy
  cols <- .strategy_columns(st)
  miss <- setdiff(cols, names(data))
  if (length(miss))
    stop(sprintf("%s: %s %s der inneren Strategie %s in data (vorhanden: %s).", who,
                 if (length(miss) == 1L) "Kursspalte" else "Kursspalten", paste0("'", miss, "'", collapse = ", "),
                 if (length(miss) == 1L) "fehlt" else "fehlen", paste(setdiff(names(data), "date"), collapse = ", ")),
         call. = FALSE)
  has <- Reduce(`|`, lapply(cols, function(cc) !is.na(data[[cc]])))
  if (!any(has))
    stop(sprintf("%s: die inneren Kursspalten (%s) enthalten nur NA.", who, paste(cols, collapse = ", ")), call. = FALSE)
  r0 <- which(has)[1L]
  d <- data
  if (r0 > 1L) {
    fa <- attr(data, "filled")
    d <- data[r0:nrow(data), , drop = FALSE]; rownames(d) <- NULL
    if (is.matrix(fa) && nrow(fa) == nrow(data)) attr(d, "filled") <- fa[r0:nrow(fa), , drop = FALSE]
  }
  S <- wrapper$volume %||% 100

  # Paketzustand der Ordergebuehren sichern; die innere Rechnung setzt ihn zurueck
  fee_old <- as.list(.fee_env, all.names = TRUE)
  on.exit({
    rm(list = ls(.fee_env, all.names = TRUE), envir = .fee_env)
    for (k in names(fee_old)) assign(k, fee_old[[k]], envir = .fee_env)
  }, add = TRUE)
  res <- tryCatch(
    withCallingHandlers(
      simulation(d, st, start_value = S, costs = sim_costs(order_fee = wrapper$order_fee), rebalance = wrapper$rebalance,
                 splits = splits, tax = NULL, fractions = TRUE),
      message = function(m) {
        message(sprintf("Hinweis: %s (innere Rechnung): %s", tag, sub("^Hinweis: ", "", conditionMessage(m))), appendLF = FALSE)
        invokeRestart("muffleMessage")
      },
      warning = function(w) {
        warning(sprintf("%s (innere Rechnung): %s", who, conditionMessage(w)), call. = FALSE)
        invokeRestart("muffleWarning")
      }),
    error = function(e) stop(sprintf("%s (innere Rechnung): %s", who, conditionMessage(e)), call. = FALSE))

  idx <- match(d$date, res$dates)
  idx <- idx[!res$filled[idx]]
  if (!length(idx))
    stop(sprintf("%s: keine Handelstage in der inneren Rechnung (alle Tage aufgef\u00fcllt).", who), call. = FALSE)
  dates <- res$dates[idx]; G <- res$worth[idx]
  day <- as.numeric(dates); yr <- as.integer(format(dates, "%Y"))
  fee <- wrapper$costs$fee; pf <- wrapper$costs$performance_fee
  n <- length(idx)
  nav <- gross <- fee_t <- acc_t <- paid_t <- hwm <- numeric(n)
  U <- 100; H <- 100; G_prev <- S; d_prev <- as.numeric(res$dates[1L])
  for (t in seq_len(n)) {
    g <- G[t]
    if (!(G_prev > 0) || !is.finite(g) || !(g > 0))
      stop(sprintf("%s: innerer Wert am %s ist %s (vorher %s); der Anteilswert ist dann nicht definiert.", who,
                   format(dates[t]), format(g), format(G_prev)), call. = FALSE)
    D <- if (.wrapper_is_leap(yr[t])) 366 else 365
    a <- U * (g / G_prev)
    k <- fee / 100 * (day[t] - d_prev) / D
    fee_t[t] <- a * k
    U <- a - fee_t[t]
    acc_t[t] <- pf / 100 * max(0, U - H)
    nav[t] <- U - acc_t[t]
    if (t < n && yr[t + 1L] != yr[t]) {          # letzter NAV-Tag des Kalenderjahres (nicht der letzte insgesamt)
      paid_t[t] <- acc_t[t]
      U <- nav[t]
      H <- max(H, U)
    }
    gross[t] <- 100 * g / S
    hwm[t] <- H
    G_prev <- g; d_prev <- day[t]
  }
  out <- data.frame(date = dates, nav = nav, gross = gross, fee = fee_t, perf_fee = acc_t, perf_paid = paid_t, hwm = hwm)
  attr(out, "inner") <- res
  attr(out, "wrapper") <- wrapper
  class(out) <- c("SimLevWrapperNav", "data.frame")
  out
}

#' Anteilswert eines Fonds-Wrappers
#' @export
#' @noRd
wrapper_nav <- function(data, wrapper, splits = NULL) {
  if (!inherits(wrapper, "SimLevWrapperConfig"))
    stop(sprintf("wrapper_nav: wrapper muss ein Objekt aus wrapper_config() sein, nicht %s.",
                 if (missing(wrapper) || is.null(wrapper)) "NULL" else paste(class(wrapper), collapse = "/")), call. = FALSE)
  if (!is.null(splits) && !inherits(splits, "SimLevSplitRule"))
    stop(sprintf("wrapper_nav: splits muss NULL oder ein Objekt aus split_rule() sein, nicht %s.",
                 paste(class(splits), collapse = "/")), call. = FALSE)
  if (missing(data) || !is.data.frame(data) || !"date" %in% names(data))
    stop("wrapper_nav: data muss ein data.frame mit Spalte 'date' und den Kursspalten der inneren Strategie sein.", call. = FALSE)
  fa <- attr(data, "filled")
  if (!identical(class(data), "data.frame")) data <- as.data.frame(data, stringsAsFactors = FALSE)
  data$date <- .to_date(data$date, "wrapper_nav: data$date")
  if (anyNA(data$date)) stop(sprintf("wrapper_nav: Spalte 'date' enth\u00e4lt NA (erstmals in Zeile %d).", which(is.na(data$date))[1]),
                             call. = FALSE)
  if (is.unsorted(data$date)) {                  # nach Datum sortieren (wie simulation())
    o <- order(data$date)
    data <- data[o, , drop = FALSE]; rownames(data) <- NULL
    if (is.matrix(fa) && nrow(fa) == length(o)) fa <- fa[o, , drop = FALSE]
  }
  if (is.matrix(fa) && nrow(fa) == nrow(data)) attr(data, "filled") <- fa
  .wrapper_nav_calc(data, wrapper, splits, tag = "wrapper_nav", who = "wrapper_nav")
}

#' Auswahl aus einem SimLevWrapperNav (Etappe 8.0)
#'
#' Jede Auswahl von Zeilen oder Spalten (x[i, ], x[j], x[i, j], x[], ueber `[` auch head(), tail() und
#' subset()) liefert einen gewoehnlichen data.frame ohne Klasse SimLevWrapperNav und ohne die Attribute
#' inner und wrapper: das innere Ergebnis passt nach einer Auswahl nicht mehr zum Ausschnitt. Gleich in
#' Python (pandas.DataFrame ohne attrs) und Julia (rows(): RFrame ohne Klasse und Attribute).
#' @export
#' @noRd
`[.SimLevWrapperNav` <- function(x, ...) {
  attr(x, "inner") <- NULL
  attr(x, "wrapper") <- NULL
  class(x) <- "data.frame"
  x[...]
}

#' @export
#' @noRd
print.SimLevWrapperNav <- function(x, ...) {
  w <- attr(x, "wrapper")
  if (!inherits(w, "SimLevWrapperConfig") || !nrow(x) || !all(c("date", "nav", "gross") %in% names(x))) {
    print(as.data.frame(unclass(x), stringsAsFactors = FALSE)); return(invisible(x))
  }
  n <- nrow(x)
  .blk_print("Anteilswert (wrapper_nav)",
             list("Zeitraum" = sprintf("%s bis %s (%d %s)", format(x$date[1]), format(x$date[n]), n,
                                       if (n == 1L) "Datentag" else "Datentage"),
                  "Fondskosten" = sprintf("%s %% p. a.", .blk_fmt(w$costs$fee)),
                  "Performancegeb\u00fchr" = sprintf("%s %% \u00fcber dem H\u00f6chststand", .blk_fmt(w$costs$performance_fee)),
                  "Endwert" = sprintf("%.4f (brutto %.4f, Start 100)", x$nav[n], x$gross[n])))
  invisible(x)
}
