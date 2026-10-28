\encoding{UTF-8}
\name{rebalance_trigger}
\alias{rebalance_trigger}
\title{Ereignis-Trigger-Spalte für Rebalancing vorberechnen}
\description{
  Berechnet eine binäre Trigger-Spalte, die \code{\link{simulation}} über
  \code{event_col} konsumiert. Die gesamte Schwellenwert-/Bandlogik liegt
  hier, außerhalb der Engine — der Nutzer kann sie nach Bedarf anpassen oder
  ersetzen.

  Vier Trigger-Typen sind implementiert:
  \describe{
    \item{\code{"abs_leverage"}}{
      Trigger, wenn die absolute Abweichung des Ziel-Hebels vom zuletzt
      gehaltenen Hebel größer als \code{threshold} ist.
    }
    \item{\code{"rel_leverage"}}{
      Trigger, wenn die relative Abweichung des Ziel-Hebels vom zuletzt
      gehaltenen Hebel größer als \code{threshold} ist.
    }
    \item{\code{"vol_band"}}{
      Trigger, wenn die Volatilität relativ zum letzten Rebalancing-Referenzwert
      um mehr als \code{threshold} abweicht.
    }
    \item{\code{"combined"}}{
      OR-Verknüpfung mehrerer Sub-Trigger-Specs aus \code{triggers}.
    }
  }
  Der Referenzwert (gehaltener Hebel bzw. Volatilität) ist der erste nicht
  fehlende Wert (in der Regel der erste Tag; bei führenden \code{NA}, etwa in
  der Anlaufphase einer EWMA-Volatilität, der erste Tag mit Wert; bis dahin
  wird nicht ausgelöst) und wird nur an Tagen fortgeschrieben, an denen dieser Trigger
  auslöst (nicht an kalendarischen Rebalancing-Tagen in
  \code{\link{simulation}}). Ausgelöst wird bei einer Abweichung
  \emph{größer} als die Schwelle; \code{NA}-Werte lösen nicht aus. Bei
  \code{"rel_leverage"} und \code{"vol_band"} wird nicht ausgelöst, solange
  der Referenzwert 0 ist.
}
\usage{
rebalance_trigger(
  df,
  type,
  threshold = 10,
  lev_col   = "target_leverage",
  vol_col   = "sigma_ewma",
  triggers  = NULL,
  out_col   = "rebal_trigger"
)
}
\arguments{
  \item{df}{
    \code{data.frame} mit täglichen Feldern (mindestens eine Zeile). Muss die
    relevanten numerischen Spalten (\code{lev_col} bzw. \code{vol_col})
    enthalten, sonst Fehler.
  }
  \item{type}{
    Character. Trigger-Typ: \code{"abs_leverage"}, \code{"rel_leverage"},
    \code{"vol_band"} oder \code{"combined"}. Kein Standardwert; andere
    Werte führen zu einem Fehler.
  }
  \item{threshold}{
    Numerisch. Auslöseschwelle \strong{in Prozent} (Paket-Konvention).
    Bedeutung je Typ: \code{"abs_leverage"} in Prozentpunkten des Hebels
    (\code{10} = 0,10 Hebelabweichung); \code{"rel_leverage"}/\code{"vol_band"}
    relative Abweichung (\code{10} = 10 \%). Bei \code{type = "combined"}
    ignoriert (Schwellen je Sub-Trigger). Standard: \code{10}.
  }
  \item{lev_col}{
    Character. Name der Ziel-Hebel-Spalte in \code{df}. Wird von
    \code{"abs_leverage"} und \code{"rel_leverage"} verwendet.
    Standard: \code{"target_leverage"}.
  }
  \item{vol_col}{
    Character. Name der Volatilitätsspalte in \code{df}. Wird von
    \code{"vol_band"} verwendet. Standard: \code{"sigma_ewma"}.
  }
  \item{triggers}{
    Liste von Sub-Trigger-Specs (nur bei \code{type = "combined"}).
    Jeder Eintrag ist eine Liste mit \code{type} und ggf. \code{threshold}
    (in Prozent, fehlt er: \code{10}), \code{lev_col}, \code{vol_col}.
    Jeder Sub-Trigger führt seinen eigenen Referenzwert; die Ergebnisse
    werden OR-verknüpft. Standard: \code{NULL}.
  }
  \item{out_col}{
    Character. Name der zu erzeugenden logischen Spalte in \code{df}.
    Standard: \code{"rebal_trigger"}.
  }
}
\value{
  \code{df} mit einer zusätzlichen logischen Spalte \code{out_col}.
  \code{TRUE} bedeutet: an diesem Tag wird Rebalancing ausgelöst.
  Tag 1 ist immer \code{FALSE} (kein Rebalancing am Einstiegstag).
}
\examples{
set.seed(42)
n <- 500
data <- data.frame(
  date             = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n),
  ETF              = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)),
  target_leverage  = 2 + 0.5 * sin(seq(0, 4 * pi, length.out = n)),
  sigma_ewma       = 0.01 + 0.005 * abs(rnorm(n))
)

# Absoluter Hebel-Trigger (Abweichung > 10 Prozentpunkte)
data <- rebalance_trigger(data, type = "abs_leverage", threshold = 10)
sum(data$rebal_trigger)  # Anzahl Rebalancing-Tage

# Vola-Band-Trigger
data <- rebalance_trigger(data, type = "vol_band",
                              threshold = 20, out_col = "rebal_vol")

# Kombinierter Trigger (OR)
data <- rebalance_trigger(data, type = "combined",
  triggers = list(
    list(type = "abs_leverage", threshold = 10),
    list(type = "vol_band",     threshold = 20)
  ),
  out_col = "rebal_combined"
)

# In simulation() verwenden
strategy <- create_strategy(
  ETF = asset_config("etf", trading = "bnh",
                     share = 1, spread = 0.1, partial_exemption = 30)
)
result <- simulation(data, strategy, start_value = 10000, rebalance = rebalance_plan(event_col = "rebal_trigger", event_mode = "replace", skip = TRUE))
}
\seealso{
  \code{\link{simulation}} (\code{event_col}, \code{event_mode},
  \code{event_weight})
}
