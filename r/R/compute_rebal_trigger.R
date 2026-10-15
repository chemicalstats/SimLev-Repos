# =============================================================================
#  compute_rebal_trigger.R  —  Vorberechnung der Event-Trigger-Spalte
# -----------------------------------------------------------------------------
#  Liefert die binaere Spalte, die simulation(..., event_col = "...") konsumiert.
#  Die gesamte Band-/Schwellenwert-Logik liegt HIER, ausserhalb der Engine.
# =============================================================================

#' Ereignis-Trigger-Spalte fuer Rebalancing vorberechnen
#'
#' Erzeugt eine logische Spalte fuer simulation(..., event_col = ...). Die
#' Referenz (Hebel bzw. Volatilitaet) ist der erste nicht fehlende Wert (bei
#' fuehrenden NA, z. B. EWMA-Anlaufphase, ein spaeterer Tag) und springt nur
#' an Tagen, an denen dieser Trigger ausloest; NA-Werte loesen nicht aus.
#' Massgebliche Beschreibung: Hilfeseite \code{?compute_rebal_trigger}.
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
compute_rebal_trigger <- function(df, type,
                                  threshold = 10,
                                  lev_col   = "target_leverage",
                                  vol_col   = "sigma_ewma",
                                  triggers  = NULL,
                                  out_col   = "rebal_trigger"){
  n <- nrow(df)
  if(n < 1L) stop("compute_rebal_trigger: leerer data.frame.")
  threshold <- threshold / 100               # PROZENT-KONVENTION (Sub-Trigger via Rekursion)
  trig <- logical(n)                         # Tag 1 (Einstieg) bleibt immer FALSE
  # R1-21: Referenz = erster nicht fehlender Wert (z. B. nach EWMA-Anlaufphase);
  # bis dahin und bei NA kein Trigger. Nur NA -> nie ein Trigger.
  .first_obs <- function(v) { i <- which(!is.na(v))[1]; if (is.na(i)) length(v) else i }

  if(type == "abs_leverage"){
    # Trigger, wenn |target_leverage[t] - lev_held[t-1]| > threshold
    if(is.null(df[[lev_col]])) stop(sprintf("Spalte '%s' fehlt.", lev_col))
    lev  <- as.numeric(df[[lev_col]]); t0 <- .first_obs(lev); held <- lev[t0]
    if(t0 < n) for(t in (t0 + 1L):n){
      if(!is.na(lev[t]) && abs(lev[t] - held) > threshold){ trig[t] <- TRUE; held <- lev[t] }
    }

  } else if(type == "rel_leverage"){
    # Trigger, wenn |target_leverage[t]/lev_held[t-1] - 1| > threshold
    if(is.null(df[[lev_col]])) stop(sprintf("Spalte '%s' fehlt.", lev_col))
    lev  <- as.numeric(df[[lev_col]]); t0 <- .first_obs(lev); held <- lev[t0]
    if(t0 < n) for(t in (t0 + 1L):n){
      if(!is.na(lev[t]) && held != 0 && abs(lev[t]/held - 1) > threshold){ trig[t] <- TRUE; held <- lev[t] }
    }

  } else if(type == "vol_band"){
    # Trigger, wenn |vol[t]/vol[t_last_rebal] - 1| > threshold
    if(is.null(df[[vol_col]])) stop(sprintf("Spalte '%s' fehlt.", vol_col))
    vol <- as.numeric(df[[vol_col]]); t0 <- .first_obs(vol); ref <- vol[t0]
    if(t0 < n) for(t in (t0 + 1L):n){
      if(!is.na(vol[t]) && ref != 0 && abs(vol[t]/ref - 1) > threshold){ trig[t] <- TRUE; ref <- vol[t] }
    }

  } else if(type == "combined"){
    # OR-Verknuepfung beliebig vieler Sub-Trigger (jeder mit eigener Referenz-Fortschreibung)
    if(is.null(triggers) || length(triggers) == 0)
      stop("type='combined' ben\u00f6tigt eine nicht-leere Liste 'triggers'.")
    for(sub in triggers){
      args   <- modifyList(list(df = df, out_col = "..__sub__.."), sub)
      sub_df <- do.call(compute_rebal_trigger, args)
      trig   <- trig | sub_df[["..__sub__.."]]
    }

  } else stop(sprintf("Unbekannter type='%s'.", type))

  df[[out_col]] <- trig
  df
}
