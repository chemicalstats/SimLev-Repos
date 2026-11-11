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
#' @param triggers  Nur bei "combined": Liste von Sub-Trigger-Specs (type + Parameter), OR-verknuepft.
#' @param out_col   Name der zu erzeugenden Trigger-Spalte. Standard "rebal_trigger".
#' @return df mit zusaetzlicher logischer Spalte `out_col` (Tag 1 immer FALSE).
#' @export
#' @noRd
rebalance_trigger <- function(df, type,
                                  threshold = 10,
                                  lev_col   = "target_leverage",
                                  vol_col   = "sigma_ewma",
                                  triggers  = NULL,
                                  out_col   = "rebal_trigger"){
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

  if(type == "abs_leverage"){
    # Trigger, wenn |target_leverage[t] - lev_held[t-1]| > threshold
    lev  <- .col(lev_col, "lev_col"); t0 <- .first_obs(lev); held <- lev[t0]
    if(t0 < n) for(t in (t0 + 1L):n){
      if(!is.na(lev[t]) && abs(lev[t] - held) > threshold){ trig[t] <- TRUE; held <- lev[t] }
    }

  } else if(type == "rel_leverage"){
    # Trigger, wenn |target_leverage[t]/lev_held[t-1] - 1| > threshold
    lev  <- .col(lev_col, "lev_col"); t0 <- .first_obs(lev); held <- lev[t0]
    if(t0 < n) for(t in (t0 + 1L):n){
      if(!is.na(lev[t]) && held != 0 && abs(lev[t]/held - 1) > threshold){ trig[t] <- TRUE; held <- lev[t] }
    }

  } else if(type == "vol_band"){
    # Trigger, wenn |vol[t]/vol[t_last_rebal] - 1| > threshold
    vol <- .col(vol_col, "vol_col"); t0 <- .first_obs(vol); ref <- vol[t0]
    if(t0 < n) for(t in (t0 + 1L):n){
      if(!is.na(vol[t]) && ref != 0 && abs(vol[t]/ref - 1) > threshold){ trig[t] <- TRUE; ref <- vol[t] }
    }

  } else {
    # "combined": OR-Verknuepfung beliebig vieler Sub-Trigger (jeder mit eigener Referenz-Fortschreibung)
    # seit K43 T1-R5 aus der Tabelle (bis dahin "type='combined' benoetigt eine nicht-leere Liste 'triggers'.")
    if (is.null(triggers)) chk_stop("fehlt", fn, "triggers")
    if (length(triggers) == 0) chk_stop("ut1.liste_leer", fn, "triggers")
    if (!is.list(triggers) || is.data.frame(triggers)) chk_stop("liste", fn, "triggers")
    for (i in seq_along(triggers)) {
      sub <- triggers[[i]]
      if (!is.list(sub) || is.data.frame(sub)) chk_stop("liste", fn, sprintf("triggers[[%d]]", i))
      nm <- names(sub); if (is.null(nm)) nm <- rep("", length(sub))
      bad <- nm[!nm %in% c("type", "threshold", "lev_col", "vol_col", "triggers", "df")]
      if (length(bad)) chk_stop("e1.trigger_feld", fn, bad[1], i)
      if (is.null(sub$type)) chk_stop("fehlt", fn, sprintf("triggers[[%d]]$type", i))
    }
    for(sub in triggers){
      args   <- list(df = df, out_col = "..__sub__..")   # wie modifyList, aber ohne Zusammenfuehren der Spalten von df
      for (k in names(sub)) args[k] <- list(sub[[k]])
      args   <- args[!vapply(args, is.null, NA)]
      sub_df <- do.call(rebalance_trigger, args)
      if (nrow(sub_df) != n) chk_stop("e1.trigger_df", fn, n)   # eigenes df eines Teil-Triggers: gleiche Zeilenzahl
      trig   <- trig | sub_df[["..__sub__.."]]
    }
  }

  df[[out_col]] <- trig
  df
}
