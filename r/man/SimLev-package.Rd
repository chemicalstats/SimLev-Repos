\encoding{UTF-8}
\name{SimLev-package}
\alias{SimLev-package}
\alias{SimLev}
\docType{package}
\title{SimLev: Backtesting und Planung mit deutscher Investmentbesteuerung}
\description{
  SimLev rechnet Anlagestrategien auf täglichen Preisreihen durch und bildet
  dabei die deutsche Investmentbesteuerung Tag für Tag ab. Die Engine
  berechnet keine Hebelung intern — Hebelung, Dividenden und
  Finanzierungskosten sind Bestandteil der Inputreihe. Um die Engine herum
  gibt es Werkzeuge zur Datenaufbereitung, zum Erzeugen von Pfaden, zur
  Auswertung fertiger Simulationen, zur Entnahmeplanung und für statistische
  Prüfungen. Die Änderungen je Version stehen in \file{NEWS.md}
  (\code{news(package = "SimLev")}); das Tutorial liegt unter
  \code{system.file("tutorial", package = "SimLev")}.
}
\section{Arbeitsweise: Daten – Simulation – Weiterverarbeitung}{
  \strong{1. Eigene Daten einlesen.} Alle Funktionen erwarten ein
  \code{data.frame} mit einer Spalte \code{date} (Klasse \code{Date}) und
  je Anlage einer Spalte mit dem \emph{Kursniveau} (keine Renditen), z. B.
  aus \code{read.csv()}. Vorbereitung:
  \code{\link{series_check}} (Lücken, Sprünge, stehende Kurse),
  \code{\link{series_align}} (mehrere Quellen auf einen Kalender),
  \code{\link{series_align_macro}} (Makroreihen mit Veröffentlichungsverzug),
  \code{\link{series_convert_currency}}, \code{\link{index_total_return}},
  \code{\link{series_deflate}}, \code{\link{series_splice}} sowie
  \code{\link{backcast_fit}}/\code{\link{backcast}} (Produkthistorie aus
  einem Basisindex zurückrechnen).

  \strong{2. Daten erzeugen.} Synthetische oder simulierte Reihen im selben
  Format liefern \code{\link{series_leverage}},
  \code{\link{index_bond}}, \code{\link{index_money_market}},
  \code{\link{index_currency_hedged}}, \code{\link{series_shift_return}}
  (eigene Renditeannahme), \code{\link{bootstrap}} mit
  \code{\link{bootstrap_data}} (ein Pfad als \code{data.frame} für
  \code{\link{simulation}}), \code{\link{bootstrap_pooled}} und
  \code{\link{scenario_copula}}.

  \strong{3. Simulieren.} \code{\link{simulation}} mit einer Strategie aus
  \code{\link{asset_config}} und \code{\link{create_strategy}} (oder
  \code{\link{strategy_from_weights}}); mit \code{taxable_income} rechnet
  \code{\link{simulation}} § 23-Steuer und Günstigerprüfung nach dem
  Einkommensteuertarif, den \code{\link{tax_tariff}} aus einer
  austauschbaren Datei liest (mitgeliefert: Rechtslage ab VZ 2026,
  Einzelveranlagung); taktische Zielgewichte führt
  \code{\link{tactical_simulation}} aus, viele Pfade
  \code{\link{bootstrap_study}}, viele Parameter \code{\link{param_search}}
  und \code{\link{sensitivity_grid}}.

  \strong{4. Fertige Simulationen weiterverarbeiten.} Ein
  \code{SimLevResult} (auch mit \code{saveRDS()} gespeichert und später
  geladen) oder eine Liste davon geht an \code{\link{result_analysis}},
  \code{\link{result_heatmap}}, \code{\link{sharpe_test}},
  \code{\link{sharpe_min_track_record}}, \code{\link{result_index}} (Wertindex als
  \code{data.frame}) und \code{\link{withdrawal_paths}} bzw.
  \code{\link{withdrawal_simulation}} (Entnahmephase auf gerechneten
  Pfaden; mit \code{start_value} = Ergebnis einer Ansparphase mit
  \code{tax_mode = "person"} übernimmt sie die offenen Lots per FIFO sowie
  Teilfreistellung, Verlusttopf, halben Spread und den Stand des
  Sparer-Pauschbetrags aus \code{tax_report$next_year}). Studien und Parametersuchen werten
  \code{\link{bootstrap_probability}}, \code{\link{overfit_pbo}},
  \code{\link{sharpe_deflated}}, \code{\link{overfit_reality_check}} und
  \code{\link{sharpe_haircut}} aus. Grafiken: \code{plot()},
  \code{\link{export_dashboard}} (PDF).
}
\section{Glossar: Einheiten und Argumentnamen}{
  Die Argumentnamen sind über die Funktionen gewachsen und nicht überall
  einheitlich. Die folgenden Regeln gelten paketweit; die Hilfeseite jeder
  Funktion nennt die Einheit jedes Arguments.
  \describe{
    \item{Prozent-Konvention}{Steuersätze, Spreads, Gebühren, TER, Zinsen,
      Inflation, Entnahmeraten, Zielvolatilitäten und Toleranzbänder werden
      in \strong{Prozent} angegeben (\code{5} = 5 \%), z. B.
      \code{tax_rate = 26.375}, \code{spread = 0.1},
      \code{risk_free = 2}, \code{balance_thresh = 5}, \code{rate = 4}.}
    \item{Anteile (0 bis 1)}{Gewichte (\code{share},
      \code{weights}, \code{lower}/\code{upper} in
      \code{\link{portfolio_optimize}}, \code{base},
      \code{min_exposure}/\code{max_exposure}) und Wahrscheinlichkeiten
      bzw. Quantile (\code{alpha}, \code{q}, \code{quantiles},
      \code{tail_q}, \code{prob}, \code{success}, \code{upper}/\code{lower}
      in \code{\link{tactical_conditional_volatility}}). Ausnahme:
      \code{stock_share} in \code{\link{withdrawal_rule}} ist in Prozent
      (\code{60} = 60 \%).}
    \item{Ergebnisse}{Kennzahlen von \code{\link{simulation}},
      \code{\link{result_analysis}} und \code{\link{bootstrap_study_metrics}} (CAGR,
      Volatilität, Drawdown) sind Anteile (\code{0.05} = 5 \%). Mit
      Sparplan ist \code{cagr} in \code{\link{simulation}} die
      geldgewichtete Rendite (XIRR), Drawdowns sind zeitgewichtet; nicht
      definierte Kennzahlen (\code{NA}) stehen mit Ursache in
      \code{undefined_metrics}. Die
      Renditen in \code{\link{tail_regression}},
      \code{\link{tail_covar}} und den Szenario-Funktionen sind Prozent
      je Periode.}
    \item{Wiederholungen}{\code{B} (Bootstrap-Wiederholungen in
      \code{\link{dependence_analysis}}, \code{\link{tail_regression}},
      \code{\link{overfit_reality_check}}, \code{\link{sharpe_test}}), \code{n}
      (Anzahl Pfade oder Szenarien in \code{\link{bootstrap}},
      \code{\link{bootstrap_study}}, \code{\link{bootstrap_pooled}},
      \code{\link{scenario_copula}}), \code{n_sim} (Simulationspfade in
      \code{\link{planning_goal}}).}
    \item{Blocklänge}{Mittlere Länge der Blöcke im Block-Bootstrap:
      \code{block} (in Perioden der gewählten \code{frequency}),
      \code{L} bzw. \code{block_length} in den Verfahrensparametern von
      \code{\link{bootstrap}} (in Zeilen) und \code{L} in
      \code{\link{bootstrap_pooled}} (in Perioden).}
    \item{\code{frequency}, \code{every}, \code{rebalance}}{
      \code{frequency} ist die Periodenlänge, auf der Renditen gemessen
      werden (\code{"day"}, \code{"week"}, \code{"month"}, \dots).
      \code{every} ist der Entscheidungs- bzw. Anpassungsrhythmus von
      Gewichts-Erzeugern. \code{rebalance} ist in
      \code{\link{tactical_simulation}} der Handelsrhythmus (Text), in
      \code{\link{scenario_crisis}} ein Schalter (\code{TRUE}/\code{FALSE}).
      In \code{\link{simulation}} heißen die Rebalancing-Argumente
      \code{balance_*}.}
    \item{Toleranzband}{Dieselbe Idee heißt \code{balance_thresh}
      (\code{\link{simulation}}), \code{tolerance}
      (\code{\link{tactical_simulation}}) und \code{bands}
      (\code{\link{sensitivity_rebalancing}}), jeweils in Prozent. Das
      Argument \code{band} der Signal-Bausteine ist dagegen eine Hysterese
      um den Schwellenwert.}
    \item{\code{horizon}}{In \code{\link{planning_goal}} Anzahl Perioden,
      in \code{\link{signal_analysis}} Zeilen der Daten, in
      \code{\link{planning_lumpsum_vs_dca}} Jahre,
      in \code{\link{backcast_fit}} Produktbeobachtungen, in
      \code{\link{withdrawal_simulation}} ein Objekt aus
      \code{\link{withdrawal_horizon}} oder eine Zahl in Jahren.
      \code{\link{withdrawal_rule}} hat kein \code{horizon}; die Restjahre
      der Regeln ergeben sich aus der Zahl der Planjahre der Simulation.}
    \item{\code{inflation}}{Je nach Funktion der Name einer Spalte bzw.
      Zusatzreihe, eine konstante Rate in Prozent p. a. oder eine
      Preisindex-Tabelle; die Hilfeseite nennt die zulässigen Formen. Ob eine
      Zusatzreihe ein Niveau oder eine Rate in Prozent p. a. ist, legt
      \code{aux_type} in \code{\link{bootstrap_config}} fest
      (\code{"level"} bzw. \code{"rate"}); eine ausdrückliche Angabe gilt
      in allen weiterverarbeitenden Funktionen, sonst
      \code{inflation_type} (\code{"level"} oder \code{"rate_pa"}) in
      \code{\link{withdrawal_paths}} und \code{\link{withdrawal_cohorts}}.}
    \item{\code{taxable_income}}{Zu versteuerndes Einkommen ohne die
      Erträge der Simulation in \strong{EUR je Kalenderjahr}
      (\code{\link{simulation}}). In der Tarifdatei von
      \code{\link{tax_tariff}} sind \code{ab}, \code{bezug},
      \code{teiler} und \code{c} in EUR; bei linearen Zonen ist \code{b}
      der Grenzsteuersatz als Anteil (\code{0.42}), die Soli-Sätze stehen
      in Prozent (\code{5.5}, \code{11.9}).}
    \item{\code{ppy}}{Perioden je Jahr für die Annualisierung. Ohne Angabe
      meist aus den Daten geschätzt (Perioden geteilt durch Jahre);
      \code{\link{sharpe_probabilistic}} und \code{\link{sharpe_haircut}}
      verwenden für Vektoren den Standard 52, die Signal-Bausteine 365.25.}
    \item{\code{partial_exemption}}{Teilfreistellung in Prozent (30 Aktienfonds,
      15 Mischfonds, 0 sonst).}
  }
}
\section{Steuerliche Modellphilosophie}{
  Die Engine projiziert die \emph{aktuelle} Rechtslage in die Vergangenheit
  (aktueller Sparer-Pauschbetrag, aktuelle Teilfreistellungssätze, aktuelle
  Freigrenzen). Ziel ist die Frage „Wie hätte es ausgesehen, wenn wir damals
  zu unseren heutigen Konditionen investiert hätten?" — keine historisch
  exakte Steuerlastberechnung.
}
\section{Datenvorbereitung in der Engine}{
  Fehlende Kalendertage (Wochenenden, Feiertage) füllt
  \code{\link{simulation}} per Last-Observation-Carried-Forward (LOCF) auf.
  Aufgefüllte Tage werden im Ergebnis in \code{filled} markiert und aus
  allen renditebasierten Risikokennzahlen (Volatilität, Sharpe, Sortino,
  Schiefe, Kurtosis) ausgeschlossen.
}
\author{
  ChemicalStats von der Mauerstrasse \email{chemicalstatsy@protonmail.com}

  Maintainer: ChemicalStats von der Mauerstrasse
}
\seealso{
  \code{\link{simulation}}, \code{\link{tax_tariff}}, \code{\link{asset_config}},
  \code{\link{create_strategy}}, \code{\link{result_analysis}},
  \code{\link{withdrawal_simulation}}, \code{\link{plot.SimLevResult}}
}
\examples{
library(SimLev)

# 1. Eigene Daten: hier synthetisch, sonst z. B. read.csv() + as.Date()
set.seed(42)
n <- 3 * 365
data <- data.frame(
  date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n),
  MSCI = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)),
  BOND =  50 * cumprod(1 + rnorm(n, 1e-4, 0.004))
)
series_check(data)

# 2. Strategie und Simulation (Prozent-Konvention: 0.1 = 0,1 \% Spread)
strategy <- create_strategy(
  MSCI = asset_config("etf", trading = "bnh",
                      share = 0.7, spread = 0.1, partial_exemption = 30),
  BOND = asset_config("etf", trading = "bnh",
                      share = 0.3, spread = 0.1, partial_exemption = 0)
)
result <- simulation(data, strategy, start_value = 10000, rebalance = rebalance_plan(unit = "year"), tax = tax_profile(), liquidate = TRUE, risk_free = 2)
print(result)

# 3. Weiterverarbeitung: speichern, laden, auswerten
f <- file.path(tempdir(), "lauf.rds")
saveRDS(result, f)
da <- result_analysis(list(Strategie = readRDS(f)))
da$metrics[c("cagr", "volatility", "max_drawdown"), ]
head(result_index(result))
}
\keyword{package}
