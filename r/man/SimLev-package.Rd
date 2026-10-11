\encoding{UTF-8}
\name{SimLev-package}
\alias{SimLev-package}
\alias{SimLev}
\docType{package}
\title{SimLev: Backtesting-Engine für gehebelte ETF-Strategien}
\description{
  SimLev ist eine reine Backtest-Engine für tägliche Preisreihen mit
  besonderem Fokus auf die Deutsche Investmentbesteuerung. Die Engine
  berechnet keine Hebelung intern — Hebelung, Dividenden und
  Finanzierungskosten sind Bestandteil der Inputreihe.

  \strong{Kernfunktionen:}
  \describe{
    \item{\code{\link{simulation}}}{
      Backtestet eine Strategie auf historischen Preisdaten. Unterstützt
      Buy-and-Hold, signalgesteuerte Strategien, DCA-Sparpläne, periodisches
      und ereignisbasiertes Rebalancing sowie die Deutsche Besteuerung
      (§§ 18–20 InvStG, § 23 EStG, Vorabpauschale, Teilfreistellung,
      Sparer-Pauschbetrag, Verlustverrechnung).
    }
    \item{\code{\link{asset_config}}}{
      Erstellt und validiert die Konfiguration eines Assets
      (Assetklasse, Handelsstrategie, Spread, Teilfreistellung,
      Steuerregime).
    }
    \item{\code{\link{create_strategy}}}{
      Kombiniert mehrere \code{asset_config}-Objekte zu einer validierten
      Strategie.
    }
    \item{\code{\link{compute_rebal_trigger}}}{
      Berechnet eine binäre Trigger-Spalte für ereignisbasiertes
      Rebalancing (Hebelschwelle, Vola-Band, kombiniert).
    }
    \item{\code{\link{plot.SimLevResult}}}{
      Dashboard-Visualisierung mit konfigurierbaren Panels (Performance,
      Drawdown, Verteilung, Rolling Returns, Monats-Heatmap, Statistiken,
      Strategievergleich). Export als PDF oder interaktives HTML.
    }
  }

  \strong{Steuerliche Modellphilosophie:}
  Die Engine projiziert die \emph{aktuelle} Rechtslage in die Vergangenheit
  (aktueller Sparer-Pauschbetrag, aktuelle Teilfreistellungssätze, aktuelle
  Freigrenzen). Ziel ist die Frage „Wie hätte es ausgesehen, wenn wir damals
  zu unseren heutigen Konditionen investiert hätten?" — keine historisch
  exakte Steuerlastberechnung.

  \strong{Datenvorbereitung:}
  Fehlende Kalendertage (Wochenenden, Feiertage) werden automatisch per
  Last-Observation-Carried-Forward (LOCF) aufgefüllt. Aufgefüllte Tage
  werden in \code{results$filled} markiert und aus allen renditebasierten
  Risikokennzahlen (Volatilität, Sharpe, Sortino, Skewness, Kurtosis)
  ausgeschlossen.
}
\author{
  ChemicalStats von der Mauerstrasse \email{chemicalstatsy@protonmail.com}

  Maintainer: ChemicalStats von der Mauerstrasse
}
\seealso{
  Nützliche Links:
  \itemize{
    \item \code{\link{simulation}} — Hauptfunktion
    \item \code{\link{asset_config}} — Asset-Konfiguration
    \item \code{\link{create_strategy}} — Strategie erstellen
    \item \code{\link{compute_rebal_trigger}} — Ereignis-Trigger
    \item \code{\link{plot.SimLevResult}} — Visualisierung
  }
}
\examples{
\dontrun{
library(SimLev)

# Daten vorbereiten (Nutzer liefert eigene Preisreihen)
set.seed(42)
n <- 756
data <- data.frame(
  date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n),
  MSCI = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)),
  BOND =  50 * cumprod(1 + rnorm(n, 1e-4, 0.004))
)

# Strategie definieren
strategy <- create_strategy(
  MSCI = asset_config("etf", action_type = "bnh",
                      asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
  BOND = asset_config("etf", action_type = "bnh",
                      asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0)
)

# Simulation
result <- simulation(
  data         = data,
  strategy     = strategy,
  start_value  = 10000,
  tax_mode     = "person",
  tax_rate     = 26.375,
  balance_mode = TRUE,
  balance_unit = "year",
  liquidate    = TRUE,
  risk_free    = 2
)

# Ergebnisse
print(result)
plot(result)
export_dashboard(result, "mein_backtest.pdf")
}
}
\keyword{package}
