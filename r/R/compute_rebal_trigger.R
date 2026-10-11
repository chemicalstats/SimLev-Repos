# =============================================================================
#  compute_rebal_trigger.R  —  Vorberechnung der Event-Trigger-Spalte
# -----------------------------------------------------------------------------
#  Liefert die binaere Spalte, die simulation(..., event_col = "...") konsumiert.
#  Die gesamte Band-/Schwellenwert-Logik liegt HIER, ausserhalb der Engine.
# =============================================================================

#' Ereignis-Trigger-Spalte fuer Rebalancing vorberechnen
#'
#' @param df        data.frame mit den taeglichen Feldern.
#' @param type      "abs_leverage", "rel_leverage", "vol_band" oder "combined".
#' @param threshold numerische Schwelle IN PROZENT (Paket-Konvention, intern /100).
#'   Bedeutung je Typ: "abs_leverage": Prozentpunkte des Hebels (10 = 0,10
#'   Hebelabweichung); "rel_leverage"/"vol_band": relative Abweichung in %
#'   (10 = 10 %). Bei "combined" ignoriert (Schwellen je Sub-Trigger).
#' @param lev_col   Name der Ziel-Hebel-Spalte (fuer *_leverage). Default "target_leverage".
#' @param vol_col   Name der Vola-Spalte (fuer vol_band). Default "sigma_ewma".
#' @param triggers  Nur bei "combined": Liste von Sub-Trigger-Specs (type + Parameter), OR-verknuepft.
#' @param out_col   Name der zu erzeugenden Trigger-Spalte. Default "rebal_trigger".
#' @return df mit zusaetzlicher logischer Spalte `out_col`.
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

  if(type == "abs_leverage"){
    # Trigger, wenn |target_leverage[t] - lev_held[t-1]| > threshold
    if(is.null(df[[lev_col]])) stop(sprintf("Spalte '%s' fehlt.", lev_col))
    lev  <- as.numeric(df[[lev_col]]); held <- lev[1]
    if(n >= 2) for(t in 2:n){
      if(!is.na(lev[t]) && abs(lev[t] - held) > threshold){ trig[t] <- TRUE; held <- lev[t] }
    }

  } else if(type == "rel_leverage"){
    # Trigger, wenn |target_leverage[t]/lev_held[t-1] - 1| > threshold
    if(is.null(df[[lev_col]])) stop(sprintf("Spalte '%s' fehlt.", lev_col))
    lev  <- as.numeric(df[[lev_col]]); held <- lev[1]
    if(n >= 2) for(t in 2:n){
      if(!is.na(lev[t]) && held != 0 && abs(lev[t]/held - 1) > threshold){ trig[t] <- TRUE; held <- lev[t] }
    }

  } else if(type == "vol_band"){
    # Trigger, wenn |vol[t]/vol[t_last_rebal] - 1| > threshold
    if(is.null(df[[vol_col]])) stop(sprintf("Spalte '%s' fehlt.", vol_col))
    vol <- as.numeric(df[[vol_col]]); ref <- vol[1]
    if(n >= 2) for(t in 2:n){
      if(!is.na(vol[t]) && ref != 0 && abs(vol[t]/ref - 1) > threshold){ trig[t] <- TRUE; ref <- vol[t] }
    }

  } else if(type == "combined"){
    # OR-Verknuepfung beliebig vieler Sub-Trigger (jeder mit eigener Referenz-Fortschreibung)
    if(is.null(triggers) || length(triggers) == 0)
      stop("type='combined' benoetigt eine nicht-leere Liste 'triggers'.")
    for(sub in triggers){
      args   <- modifyList(list(df = df, out_col = "..__sub__.."), sub)
      sub_df <- do.call(compute_rebal_trigger, args)
      trig   <- trig | sub_df[["..__sub__.."]]
    }

  } else stop(sprintf("Unbekannter type='%s'.", type))

  df[[out_col]] <- trig
  df
}


# =============================================================================
#  BEISPIEL (lauffaehig) — 10-Zeilen-Minimaldatensatz
# =============================================================================
if (sys.nframe() == 0L) {
  df <- data.frame(
    date            = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 10),
    target_leverage = c(2.00,2.05,2.30,2.28,1.95,1.90,2.40,2.42,2.10,2.00),
    sigma_ewma      = c(0.10,0.11,0.16,0.15,0.10,0.10,0.20,0.22,0.14,0.12)
  )
  df <- compute_rebal_trigger(df, "abs_leverage", threshold = 10, out_col = "trig_abs")
  df <- compute_rebal_trigger(df, "rel_leverage", threshold = 10, out_col = "trig_rel")
  df <- compute_rebal_trigger(df, "vol_band",     threshold = 20, vol_col = "sigma_ewma", out_col = "trig_vol")
  df <- compute_rebal_trigger(df, "combined",
          triggers = list(list(type = "abs_leverage", threshold = 10),
                          list(type = "vol_band", threshold = 20, vol_col = "sigma_ewma")),
          out_col = "trig_comb")
  print(df[, c("target_leverage","sigma_ewma","trig_abs","trig_rel","trig_vol","trig_comb")])

  # Verdrahtung mit der Engine (Skizze, benoetigt kompiliertes Paket + simulation_event.R):
  #   res <- simulation(data = df, strategy = strategy, start_value = 10000,
  #                     event_col    = "trig_vol",            # vorberechnete Spalte
  #                     event_mode   = "replace",             # oder "additional"
  #                     event_weight = c(LETF = "target_leverage"))  # optional
}
