# =============================================================================
#  compute_rebal_trigger.R  —  Vorberechnung der Event-Trigger-Spalte
# -----------------------------------------------------------------------------
#  Liefert die binaere Spalte, die simulation(..., rebalance = rebalance_plan(event_col = "...")) konsumiert.
#  Die gesamte Band-/Schwellenwert-Logik liegt HIER, ausserhalb der Engine.
# =============================================================================

#' Ereignis-Trigger-Spalte fuer Rebalancing vorberechnen
#'
#' Erzeugt eine logische Spalte fuer simulation(..., rebalance = rebalance_plan(event_col = ...)). Die
#' Referenz (Hebel bzw. Volatilitaet) ist der erste nicht fehlende Wert (bei
#' fuehrenden NA, z. B. EWMA-Anlaufphase, ein spaeterer Tag) und springt nur
#' an Tagen, an denen dieser Trigger ausloest; NA-Werte loesen nicht aus.
#' Massgebliche Beschreibung: Hilfeseite \code{?rebalance_trigger}.
#'
#' @param df        data.frame mit den taeglichen Feldern (mindestens eine Zeile).
#' @param type      "abs_leverage", "rel_leverage", "vol_band" oder "combined" (kein Standard).
#' @param threshold numerische Schwelle IN PROZENT (Paket-Konvention, intern /100).
#'   Bedeutung je Typ: "abs_leverage": Prozentpunkte des Hebels (10 = 0,10
#'   Hebelabweichung); "rel_leverage"/"vol_band": relative Abweichung in %
#'   (10 = 10 %). Bei "combined" ignoriert (Schwellen je Sub-Trigger). Standard: 10.
#' @param lev_col   Name der Ziel-Hebel-Spalte (fuer abs_leverage/rel_leverage). Standard "target_leverage".
#' @param vol_col   Name der Vola-Spalte (fuer vol_band). Standard "sigma_ewma".
#' @param triggers  Nur bei "combined": Liste von Sub-Trigger-Specs (type + Parameter), OR-verknuepft
#'   (seit 1.6.5 mit combine = "and" UND-verknuepft).
#' @param out_col   Name der zu erzeugenden Trigger-Spalte. Standard "rebal_trigger".
#' @param combine   Nur bei "combined" (seit 1.6.5): "or" (Standard, jeder Teil-Trigger mit eigener Referenz) oder
#'   "and" (alle Teil-Trigger zugleich, gemeinsame Referenz am letzten Ausloesetag).
#' @return df mit zusaetzlicher logischer Spalte `out_col` (Tag 1 immer FALSE).
#' @export
#' @noRd
rebalance_trigger <- function(df, type,
                                  threshold = 10,
                                  lev_col   = "target_leverage",
                                  vol_col   = "sigma_ewma",
                                  triggers  = NULL,
                                  out_col   = "rebal_trigger",
                                  combine   = "or"){
  fn <- "rebalance_trigger"
  # seit 1.6.4 Eingabepruefung vor der Rechnung (A-013, A-036): df nur als Tabelle (Entscheidung 6), type aus der
  # Liste, threshold eine einzelne endliche Zahl >= 0, Spaltennamen einzeln und nicht leer, die genutzte Spalte
  # numerisch (eine Spalte nur aus NA zaehlt als Zahlenspalte, Entscheidung 14) und ohne +-Inf, Teil-Trigger von
  # "combined" als Liste mit den Feldern type, threshold, lev_col, vol_col, triggers und df (eigenes df mit gleicher
  # Zeilenzahl; out_col dort nicht).
  # Bis 1.6.3 rechneten Python und Julia z. B. mit Text-Schwellen, Inf-Werten oder fremdem out_col anders als R.
  chk_df(df, fn, "df")
  n <- nrow(df)
  if(n < 1L) chk_stop("zeilen_keine", fn, "df")   # seit K43 T1-R5 aus der Tabelle (bis dahin "leerer data.frame.")
  if (missing(type)) chk_stop("fehlt", fn, "type")
  chk_choice(type, fn, "type", c("abs_leverage", "rel_leverage", "vol_band", "combined"))
  chk_num1(threshold, fn, "threshold", lo = 0)
  chk_name1(lev_col, fn, "lev_col"); chk_name1(vol_col, fn, "vol_col"); chk_name1(out_col, fn, "out_col")
  chk_choice(combine, fn, "combine", c("or", "and"))   # seit 1.6.5 (Entscheidung 150)
  # seit 1.6.4 (Entscheidung 26): eine vorhandene Spalte wird nicht still ueberschrieben
  if (out_col %in% names(df)) chk_stop("spalte_vorhanden", fn, out_col, "df", "out_col")
  threshold <- threshold / 100               # PROZENT-KONVENTION (Sub-Trigger via Rekursion)
  trig <- logical(n)                         # Tag 1 (Einstieg) bleibt immer FALSE
  # Referenz = erster nicht fehlender Wert (z. B. nach EWMA-Anlaufphase);
  # bis dahin und bei NA kein Trigger. Nur NA -> nie ein Trigger.
  .first_obs <- function(v) { i <- which(!is.na(v))[1]; if (is.na(i)) length(v) else i }
  .col <- function(col, arg) {
    # seit K43 T1-R5 mit Funktions- und Argumentnamen (bis dahin "Spalte '<name>' fehlt.")
    if(is.null(df[[col]])) chk_stop("e2.spalte_von", fn, arg, "df")
    v <- df[[col]]
    if (is.logical(v) && all(is.na(v))) v <- as.numeric(v)
    if (is.factor(v)) chk_stop("spalte_faktor", fn, col)   # Entscheidung 15
    if (!is.numeric(v)) chk_stop("spalte_typ", fn, col, chk_msg("typ.numerisch"))
    if (any(is.infinite(v))) chk_stop("e1.spalte_endlich", fn, col)
    as.numeric(v)
  }

  # Seit 1.6.5 (CR2-D-1, Entscheidung 185 K15) vergleichen die Schwellen mit einer kleinen Toleranz (eine Abweichung
  # genau auf der Schwelle, z. B. 2.1 - 2 = 0.10000000000000009 bei 10, loest nicht aus): absolut
  # |d| > threshold + 1e-12 * max(1, |Referenz|), relativ |d| > threshold + 1e-12. Seit 1.6.5 (CR2-D-2, K14) ersetzt
  # bei "rel_leverage"/"vol_band" der erste Wert != 0 eine Referenz 0 (ohne auszuloesen; bis 1.6.4 sperrte die
  # Referenz 0 den Ausloeser fuer immer).
  if(type == "abs_leverage"){
    # Trigger, wenn |target_leverage[t] - lev_held[t-1]| > threshold
    lev  <- .col(lev_col, "lev_col"); t0 <- .first_obs(lev); held <- lev[t0]
    if(t0 < n) for(t in (t0 + 1L):n){
      if(!is.na(lev[t]) && abs(lev[t] - held) > threshold + 1e-12 * max(1, abs(held))){ trig[t] <- TRUE; held <- lev[t] }
    }

  } else if(type == "rel_leverage" || type == "vol_band"){
    # Trigger, wenn |target_leverage[t]/lev_held[t-1] - 1| > threshold bzw. |vol[t]/vol[t_last_rebal] - 1| > threshold
    lev  <- if (type == "vol_band") .col(vol_col, "vol_col") else .col(lev_col, "lev_col")
    t0 <- .first_obs(lev); held <- lev[t0]
    if(t0 < n) for(t in (t0 + 1L):n){
      if (is.na(lev[t])) next
      if (held == 0) { if (lev[t] != 0) held <- lev[t] }
      else if (abs(lev[t]/held - 1) > threshold + 1e-12) { trig[t] <- TRUE; held <- lev[t] }
    }

  } else {
    # "combined": OR-Verknuepfung beliebig vieler Sub-Trigger (jeder mit eigener Referenz-Fortschreibung)
    # seit K43 T1-R5 aus der Tabelle (bis dahin "type='combined' benoetigt eine nicht-leere Liste 'triggers'.")
    if (is.null(triggers)) chk_stop("fehlt", fn, "triggers")
    if (length(triggers) == 0) chk_stop("ut1.liste_leer", fn, "triggers")
    # seit 1.6.5 (CR2-D-3): eine benannte Liste (ein Teil-Trigger ohne aeussere Liste) meldet wie Python und Julia
    if (!is.list(triggers) || is.data.frame(triggers) || !is.null(names(triggers))) chk_stop("liste", fn, "triggers")
    for (i in seq_along(triggers)) {
      sub <- triggers[[i]]
      if (!is.list(sub) || is.data.frame(sub)) chk_stop("liste", fn, sprintf("triggers[[%d]]", i))
      nm <- names(sub); if (is.null(nm)) nm <- rep("", length(sub))
      bad <- nm[!nm %in% c("type", "threshold", "lev_col", "vol_col", "triggers", "df", "combine")]
      if (length(bad)) chk_stop("e1.trigger_feld", fn, bad[1], i)
      if (is.null(sub$type)) chk_stop("fehlt", fn, sprintf("triggers[[%d]]$type", i))
    }
    leaves <- list()
    for (i in seq_along(triggers)) {
      sub <- triggers[[i]]
      args   <- list(df = df, out_col = "..__sub__..")   # wie modifyList, aber ohne Zusammenfuehren der Spalten von df
      for (k in names(sub)) args[k] <- list(sub[[k]])
      args   <- args[!vapply(args, is.null, NA)]
      sub_df <- do.call(rebalance_trigger, args)
      if (nrow(sub_df) != n) chk_stop("e1.trigger_df", fn, n)   # eigenes df eines Teil-Triggers: gleiche Zeilenzahl
      if (combine == "or") { trig <- trig | sub_df[["..__sub__.."]]; next }
      # "and" (seit 1.6.5, Entscheidung 150): nur einfache Teil-Trigger; Spalte und Schwelle wie im Teilaufruf geprueft
      if (identical(sub$type, "combined")) chk_stop("a.trigger_und", fn, i)
      d_i <- args$df
      col <- if (identical(sub$type, "vol_band")) args$vol_col %||% "sigma_ewma" else args$lev_col %||% "target_leverage"
      v <- d_i[[col]]
      leaves[[length(leaves) + 1L]] <- list(abs = identical(sub$type, "abs_leverage"),
                                            thr = (args$threshold %||% 10) / 100, v = as.numeric(v))
    }
    if (combine == "and") {
      L <- length(leaves); ref <- rep(NA_real_, L)
      for (t in seq_len(n)) {
        ok <- TRUE
        for (j in seq_len(L)) {
          lf <- leaves[[j]]; v <- lf$v[t]
          if (is.na(v)) { ok <- FALSE; next }
          if (is.na(ref[j]) || (!lf$abs && ref[j] == 0)) {   # Referenz setzen (erster Wert, bei relativ erster Wert != 0)
            if (is.na(ref[j]) || v != 0) ref[j] <- v
            ok <- FALSE; next
          }
          hit <- if (lf$abs) abs(v - ref[j]) > lf$thr + 1e-12 * max(1, abs(ref[j]))
                 else abs(v / ref[j] - 1) > lf$thr + 1e-12
          if (!hit) ok <- FALSE
        }
        if (ok) { trig[t] <- TRUE; for (j in seq_len(L)) ref[j] <- leaves[[j]]$v[t] }
      }
    }
  }

  df[[out_col]] <- trig
  df
}
