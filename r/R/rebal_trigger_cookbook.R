# =============================================================================
#  rebal_trigger_cookbook.R
#  Manuelle Vorberechnung der Event-/Vol-Signalspalte (event_col) — OHNE
#  built-in Funktion. Der User legt die TRUE/FALSE-Spalte selbst im Datensatz
#  an und uebergibt sie via simulation(..., event_col = "<spaltenname>").
#
#  Gemeinsames Prinzip aller Hebel-/Vol-Varianten:
#  Die Referenzgroesse ("zuletzt gehaltener Hebel" bzw. "Vola am letzten
#  Rebalancing-Tag") ist eine SCHRITTFUNKTION — sie springt nur an Tagen, an
#  denen tatsaechlich getriggert wurde. Deshalb braucht es eine kleine
#  stateful Schleife; eine reine vektorisierte diff()-Loesung waere falsch,
#  weil sie gegen den Vortag statt gegen den letzten Rebalancing-Tag misst.
# =============================================================================

# ── Synthetischer Beispiel-Datensatz (Kalenderraster, 1 LETF) ───────────────
set.seed(1)
df <- data.frame(
  date            = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 10),
  LETF            = 100 * cumprod(1 + c(0,0.01,0.05,-0.01,-0.08,0,0.10,0.02,-0.05,-0.02)),
  target_leverage = c(2.00,2.05,2.30,2.28,1.95,1.90,2.40,2.42,2.10,2.00),  # vom User berechnet
  sigma_ewma      = c(0.10,0.11,0.16,0.15,0.10,0.10,0.20,0.22,0.14,0.12)   # vom User berechnet
)


# ─────────────────────────────────────────────────────────────────────────────
# VARIANTE 1 — abs_leverage
#   Trigger, wenn |target_leverage[t] - lev_held[t-1]| > threshold
#   lev_held = zuletzt getriggerter target_leverage (Schrittfunktion)
# ─────────────────────────────────────────────────────────────────────────────
trigger_abs_leverage <- function(target_leverage, threshold = 0.10){
  n    <- length(target_leverage)
  trig <- logical(n)                 # Tag 1 = FALSE (Einstieg)
  held <- target_leverage[1]
  if(n >= 2) for(t in 2:n){
    if(!is.na(target_leverage[t]) && abs(target_leverage[t] - held) > threshold){
      trig[t] <- TRUE
      held    <- target_leverage[t]  # Referenz springt nach
    }
  }
  trig
}
df$trig_abs <- trigger_abs_leverage(df$target_leverage, threshold = 0.10)


# ─────────────────────────────────────────────────────────────────────────────
# VARIANTE 2 — rel_leverage
#   Trigger, wenn |target_leverage[t] / lev_held[t-1] - 1| > threshold
# ─────────────────────────────────────────────────────────────────────────────
trigger_rel_leverage <- function(target_leverage, threshold = 0.10){
  n    <- length(target_leverage)
  trig <- logical(n)
  held <- target_leverage[1]
  if(n >= 2) for(t in 2:n){
    if(!is.na(target_leverage[t]) && held != 0 &&
       abs(target_leverage[t] / held - 1) > threshold){
      trig[t] <- TRUE
      held    <- target_leverage[t]
    }
  }
  trig
}
df$trig_rel <- trigger_rel_leverage(df$target_leverage, threshold = 0.10)


# ─────────────────────────────────────────────────────────────────────────────
# VARIANTE 3 — vol_band
#   Trigger, wenn |vol[t] / vol[t_last_rebal] - 1| > threshold
#   Oekonomik: nicht der Hebelabstand triggert, sondern die Vola-Veraenderung.
# ─────────────────────────────────────────────────────────────────────────────
trigger_vol_band <- function(vol, threshold = 0.20){
  n    <- length(vol)
  trig <- logical(n)
  ref  <- vol[1]                     # Vola am letzten Rebalancing-Tag
  if(n >= 2) for(t in 2:n){
    if(!is.na(vol[t]) && ref != 0 && abs(vol[t] / ref - 1) > threshold){
      trig[t] <- TRUE
      ref     <- vol[t]
    }
  }
  trig
}
df$trig_vol <- trigger_vol_band(df$sigma_ewma, threshold = 0.20)


# ─────────────────────────────────────────────────────────────────────────────
# VARIANTE 4 — combined (OR-Verknuepfung)
#   Trigger, wenn IRGENDEIN Sub-Trigger feuert. Jeder Sub-Trigger fuehrt seine
#   eigene Referenz unabhaengig fort; danach werden die Spalten ge-OR-t.
# ─────────────────────────────────────────────────────────────────────────────
df$trig_comb <- df$trig_abs | df$trig_vol     # z.B. abs_leverage ODER vol_band

# Alternativ direkt aus den Rohgroessen, falls die Einzelspalten nicht existieren:
# df$trig_comb <- trigger_abs_leverage(df$target_leverage, 0.10) |
#                 trigger_vol_band(df$sigma_ewma, 0.20)


# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL — ereignisgetriebene Ziel-Gewichte (event_weight)
#   Spalte mit dem gewuenschten Zielgewicht je Event-Tag. Bei einem LETF ist das
#   typischerweise der (normierte) Ziel-Hebel. simulation(..., event_weight=...)
#   uebernimmt den Wert an Event-Tagen als active_targets.
# ─────────────────────────────────────────────────────────────────────────────
# Bei einem einzigen Asset ist das Zielgewicht 1 (100%); der Hebel wirkt ueber
# die Renditereihe selbst. Bei mehreren Assets z.B. anteilig:
df$w_LETF <- 1.0


# ── Kontrolle ───────────────────────────────────────────────────────────────
print(df[, c("target_leverage","sigma_ewma",
             "trig_abs","trig_rel","trig_vol","trig_comb")])

# ── Uebergabe an die Engine (Skizze; benoetigt kompiliertes Paket) ──────────
# strategy <- list(
#   LETF = list(asset_class = "etf", action_type = "bnh", asset_start = df$date[1],
#               tax_regime = "none", asset_bonus = 0, asset_share = 1.0,
#               asset_spread = 0.0,
#               signal_buy = "sig_buy", signal_sell = "sig_sell")
# )
# df$sig_buy  <- TRUE      # bnh: stets investiert
# df$sig_sell <- FALSE
#
# res <- simulation(
#   data = df, strategy = strategy, start_value = 10000,
#   event_col    = "trig_vol",                 # selbst berechnete Spalte
#   event_mode   = "replace",                  # oder "additional" (zus. zum Kalender)
#   event_weight = c(LETF = "w_LETF")          # optional
# )
