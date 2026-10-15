\encoding{UTF-8}
\name{simulation}
\alias{simulation}
\title{Portfolio-Backtest-Simulation}
\description{
Backtestet eine oder mehrere Asset-Strategien auf historischen oder
synthetischen Preisreihen. Die Engine verarbeitet jede Preisreihe so, wie
sie übergeben wird – Hebelung, Dividenden und Finanzierungskosten sind
Bestandteil der Inputreihe und werden nicht intern berechnet.

Die Simulation unterstützt Buy-and-Hold (\code{"bnh"}), signalgesteuerte
Strategien (\code{"signal"}), DCA-Sparpläne, periodisches Rebalancing,
ereignisbasiertes Rebalancing sowie die Deutsche Investmentbesteuerung
(§§ 18–20 InvStG, § 23 EStG).
}
\usage{
simulation(
  data,
  strategy,
  start_value    = 10000,
  spread         = NULL,
  details        = FALSE,
  liquidate      = FALSE,
  dca_mode       = FALSE,
  dca_value      = NULL,
  dca_span       = NULL,
  dca_days       = NULL,
  dca_unit       = c("month", "quarter", "year"),
  dca_anchor     = c("start", "end"),
  dca_start      = NULL,
  dca_skip       = FALSE,
  balance_mode   = FALSE,
  balance_span   = NULL,
  balance_days   = NULL,
  balance_unit   = c("month", "quarter", "year"),
  balance_anchor = c("start", "end"),
  balance_start  = NULL,
  balance_skip   = FALSE,
  balance_dca    = FALSE,
  balance_thresh = NULL,
  balance_thresh_type = c("absolute", "relative"),
  tax_mode       = c("none", "person", "funds"),
  tax_rate       = 26.375,
  marginal_tax_rate          = NULL,
  use_guenstigerpruefung     = FALSE,
  private_sale_threshold     = 1000,
  sparer_pauschbetrag        = 1000,
  use_sparer_pauschbetrag    = TRUE,
  include_soli_on_income_tax = FALSE,
  soli_rate_income_tax       = 5.5,
  base_rate      = NULL,
  base_rate_flex = FALSE,
  base_rate_data = NULL,
  funds_fee      = 0.95,
  bonus_fee      = 5,
  fractions      = TRUE,
  risk_free      = 0,
  split_mode     = FALSE,
  split_thresh   = NULL,
  event_col      = NULL,
  event_mode     = c("additional", "replace"),
  event_weight   = NULL
)
}
\arguments{
  \item{data}{
    \code{data.frame} mit täglichen Marktdaten. Pflichtfelder: \code{date}
    (Datum) und je eine Preisspalte pro Asset (Name muss mit dem Asset-Namen
    in \code{strategy} übereinstimmen). Optionale Spalten: \code{base_rate}
    (Basiszins für Vorabpauschale), Signalspalten (für
    \code{action_type = "signal"}), \code{risk_free} (Risk-Free-Reihe).
    Fehlende Kalendertage werden automatisch per LOCF aufgefüllt; aufgefüllte
    Tage werden in \code{filled} markiert und aus Risikometriken ausgeschlossen.
  }
  \item{strategy}{
    Benannte Liste von Asset-Konfigurationen, idealerweise erzeugt mit
    \code{\link{create_strategy}} und \code{\link{asset_config}}. Direkte
    Listen-Übergabe ist ebenfalls möglich (Backward-Kompatibilität).
  }
  \item{start_value}{
    Numerisch. Anfangskapital in EUR. Standard: \code{10000}.
  }
  \item{tax_mode}{
    Besteuerungsmodus: \code{"none"} (keine Steuer), \code{"person"}
    (persönliche Steuer nach §§ 18–20 InvStG und § 23 EStG) oder
    \code{"funds"} (pauschale Fondsbesteuerung). Standard: \code{"none"}.
  }
  \item{tax_rate}{
    Numerisch. Kapitalertragsteuersatz inkl. Solidaritätszuschlag
    \strong{in Prozent} (z. B. \code{26.375} = 25 \% KapESt + 5,5 \% Soli).
    Standard: \code{26.375}.
  }
  \item{marginal_tax_rate}{
    Numerisch oder \code{NULL}. Persönlicher Grenzsteuersatz für § 23 EStG
    \strong{in Prozent} (z. B. \code{42} = 42 \%). Nur relevant bei
    \code{tax_mode = "person"}.
  }
  \item{use_guenstigerpruefung}{
    Logisch. Günstigerprüfung nach § 32d Abs. 6 EStG anwenden?
    Standard: \code{FALSE}.
  }
  \item{sparer_pauschbetrag}{
    Numerisch. Jährlicher Sparer-Pauschbetrag in EUR. Standard: \code{1000}.
  }
  \item{use_sparer_pauschbetrag}{
    Logisch. Sparer-Pauschbetrag anwenden? Standard: \code{TRUE}.
  }
  \item{private_sale_threshold}{
    Numerisch. Freigrenze nach § 23 EStG in EUR. Standard: \code{1000}.
  }
  \item{include_soli_on_income_tax}{
    Logisch. Solidaritätszuschlag auf Einkommensteuer (§ 23-Pfad) erheben?
    Standard: \code{FALSE}.
  }
  \item{soli_rate_income_tax}{
    Numerisch. Soli-Satz \strong{in Prozent} (\code{5.5} = 5,5 \%).
    Standard: \code{5.5}.
  }
  \item{base_rate}{
    Numerisch oder \code{NULL}. Fester jährlicher Basiszins für die
    Vorabpauschale \strong{in Prozent} (z. B. \code{2.55} = 2,55 \%).
    Wird durch \code{base_rate_flex} übersteuert. \code{NULL} = kein fester Wert.
  }
  \item{base_rate_flex}{
    Logisch. Dynamischen Basiszins aus einer Datenspalte verwenden?
    Standard: \code{FALSE}.
  }
  \item{base_rate_data}{
    Character. Name der Spalte in \code{data} mit täglichen Basiszinswerten
    (annualisiert, \strong{in Prozent}). Standard: \code{"base_rate"}.
  }
  \item{dca_mode}{
    Logisch. DCA-Sparplan aktivieren? Standard: \code{FALSE}.
  }
  \item{dca_value}{
    Numerisch. Betrag pro DCA-Einzahlung in EUR. Standard: \code{0}.
  }
  \item{dca_span}{
    Numerisch. Abstand zwischen Einzahlungen (in \code{dca_unit}).
    Standard: \code{1}.
  }
  \item{dca_unit}{
    Character. Einheit des DCA-Abstands: \code{"month"}, \code{"week"},
    \code{"quarter"} oder \code{"year"}. Standard: \code{"month"}.
  }
  \item{dca_days}{
    Integer-Vektor oder \code{NULL}. Konkrete Wochentage (1 = Mo, 7 = So)
    für DCA-Zahlungen.
  }
  \item{dca_anchor}{
    Date oder \code{NULL}. Ankerdatum für periodische DCA-Berechnung.
  }
  \item{balance_mode}{
    Logisch. Periodisches Rebalancing aktivieren? Standard: \code{FALSE}.
  }
  \item{balance_span}{
    Numerisch. Rebalancing-Intervall in \code{balance_unit}. Standard: \code{1}.
  }
  \item{balance_unit}{
    Character. Einheit des Rebalancing-Intervalls: \code{"year"},
    \code{"month"} oder \code{"quarter"}. Standard: \code{"year"}.
  }
  \item{balance_thresh}{
    Numerisch oder \code{NULL}. Minimale Gewichtsabweichung \strong{in
    Prozent} (z. B. \code{5} = 5 \%) für einen Rebalancing-Trade.
    \code{NULL} = immer rebalancieren.
  }
  \item{liquidate}{
    Logisch. Portfolio am letzten Simulationstag vollständig liquidieren
    (inkl. Steuerabrechnung)? Standard: \code{FALSE}.
  }
  \item{event_col}{
    Character oder \code{NULL}. Name einer logischen Spalte in \code{data},
    die ereignisbasiertes Rebalancing auslöst (siehe
    \code{\link{compute_rebal_trigger}}). Standard: \code{NULL}.
  }
  \item{event_mode}{
    Character. \code{"additional"} (zusätzlich zum periodischen Rebalancing)
    oder \code{"replace"} (ersetzt es). Standard: \code{"additional"}.
  }
  \item{event_weight}{
    Benannte Liste oder \code{NULL}. Zielgewichte für Event-Rebalancing;
    \code{NULL} = Strategie-Gewichte.
  }
  \item{risk_free}{
    Numerisch oder Character. Annualisierte risikolose Rendite
    \strong{in Prozent} (z. B. \code{3} = 3 \% p.a.) oder Name einer
    Spalte in \code{data} mit einer täglichen, annualisierten Zeitreihe in
    Prozent (z. B. SOFR als \code{5.31}). \code{NULL} und \code{0} sind
    äquivalent. Jede Tagesrate wird in ihr Tagesäquivalent umgerechnet und
    von der jeweiligen Tagesrendite abgezogen; Sharpe und Sortino werden auf
    den Überschussrenditen berechnet. LOCF-aufgefüllte Tage werden konsistent
    ausgeschlossen. Standard: \code{0}.
  }
  \item{fractions}{
    Logisch. Bruchteile von Anteilen erlauben? Standard: \code{TRUE}.
  }
  \item{split_mode}{
    Logisch. Automatische Behandlung von Aktiensplits aktivieren?
    Standard: \code{FALSE}.
  }
  \item{split_thresh}{
    Numerisch oder \code{NULL}. Preisschwelle für Split-Erkennung.
  }
  \item{balance_thresh_type}{
    \code{"absolute"} (Standard): \code{balance_thresh} sind Prozentpunkte
    des Gewichts (5 = Ziel 40 \% darf 35--45 \% sein). \code{"relative"}:
    Prozent des Zielgewichts (25 = Ziel 40 \% darf 30--50 \% sein), wie die
    relativen Bänder bei testfol.io. Geprüft wird an den Kalenderterminen
    des Rebalancings.
  }
  \item{funds_fee}{
    Numerisch. Jährliche Fondskostenquote (TER-äquivalent) \strong{in Prozent}
    (z. B. \code{0.95} = 0,95 \% p.a.), konsistent mit der paketweiten
    Prozent-Konvention. Täglich auf das Gesamtvermögen abgegrenzt; wirkt
    nur bei \code{tax_mode = "funds"}. Standard: \code{0.95}.
  }
  \item{bonus_fee}{
    Numerisch. Jährliche Performancegebühr \strong{in Prozent} (z. B.
    \code{5} = 5 \%, Prozent-Konvention), mit High-Watermark; wirkt nur bei
    \code{tax_mode = "funds"}. Standard: \code{5}.
  }
  \item{spread}{
    Numerisch oder \code{NULL}. Globaler Spread-Override (überschreibt
    asset-spezifische Spreads). Standard: \code{NULL}.
  }
  \item{dca_start}{
    Date oder \code{NULL}. Startdatum für DCA-Zahlungen.
  }
  \item{dca_skip}{
    Logisch. Ersten DCA-Termin überspringen? Standard: \code{FALSE}.
  }
  \item{balance_days}{
    Integer-Vektor oder \code{NULL}. Konkrete Wochentage für Rebalancing.
  }
  \item{balance_anchor}{
    Character. Ankerpunkt des Rebalancing-Rhythmus: \code{"start"} oder
    \code{"end"}. Standard: \code{"start"}.
  }
  \item{balance_start}{
    Date oder \code{NULL}. Startdatum für periodisches Rebalancing.
  }
  \item{balance_skip}{
    Logisch. Ersten Rebalancing-Termin überspringen? Standard: \code{FALSE}.
  }
  \item{balance_dca}{
    Logisch. \code{FALSE} (Standard): Jede DCA-Rate wird fix nach den
    \strong{Strategie-Gewichten} (\code{asset_share}) verteilt, renormiert
    über die aktiven Assets — 70:30 bleibt 70:30, unabhängig von der
    Depot-Drift. \code{TRUE}: Die Rate wirkt als Mini-Rebalancing — sie
    füllt zuerst die Wert-Defizite zu den Strategie-Zielen; ein Rest wird
    nach Strategie-Gewichten verteilt.
  }
  \item{details}{
    Logisch. Detaillierte Steuer-/Trade-Ausgaben auf der Konsole?
    Standard: \code{FALSE}.
  }
}
\value{
  Liste der Klasse \code{"SimLevResult"} mit:
  \describe{
    \item{\code{dates}}{
      Date-Vektor. Tägliche Simulationsdaten (Kalendertage inkl. aufgefüllter
      Tage).
    }
    \item{\code{filled}}{
      Logischer Vektor (gleiche Länge wie \code{dates}). \code{TRUE} = dieser
      Tag wurde per LOCF aufgefüllt (kein echter Handelstag). Aufgefüllte Tage
      werden aus allen renditebasierten Risikometriken ausgeschlossen.
    }
    \item{\code{worth}}{
      Numerischer Vektor. Tägliche Portfoliowerte in EUR.
    }
    \item{\code{cagr}}{
      Numerisch. Compound Annual Growth Rate (annualisierte Gesamtrendite).
    }
    \item{\code{ttwror}}{
      Numerisch. True Time-Weighted Rate of Return.
    }
    \item{\code{drawdowns}}{
      Numerischer Vektor. Tägliche Drawdowns vom jeweiligen Höchststand
      (negativ, Dezimal).
    }
    \item{\code{statistics}}{
      Benannte Liste mit Risiko- und Renditekennzahlen:
      \describe{
        \item{\code{mean}}{Mittlere tägliche Rendite (Handelstage).}
        \item{\code{sd}}{Tägliche Portfoliovolatilität (Handelstage).}
        \item{\code{sharpe}}{Annualisierte Sharpe Ratio auf Überschussrenditen.}
        \item{\code{sortino}}{Annualisierte Sortino Ratio auf Überschussrenditen.}
        \item{\code{risk_free}}{Effektiv genutzte mittlere Risk-Free-Rate (annualisiert, in Prozent).}
        \item{\code{skewness}}{Schiefe der Tagesrenditen.}
        \item{\code{kurtosis}}{Kurtosis der Tagesrenditen.}
        \item{\code{max_drawdown}}{Maximaler Drawdown.}
        \item{\code{calmar}}{Calmar Ratio (CAGR / Max Drawdown).}
        \item{\code{omega}}{Omega Ratio.}
        \item{\code{ulcer_index}}{Ulcer Index.}
        \item{\code{cv}}{Variationskoeffizient.}
      }
    }
    \item{\code{report}}{
      Benannte Liste je Asset mit täglichen Cashflow- und Positionsdaten
      (\code{worth}, \code{money}, \code{flows}, \code{total}, \code{share}).
    }
    \item{\code{tax_report}}{
      Steuerzusammenfassung: \code{total_taxes_paid},
      \code{loss_carryforward_capital} (§ 20 EStG-Verlustvortrag),
      \code{loss_carryforward_private} (§ 23 EStG-Verlustvortrag),
      \code{sparer_pauschbetrag_used}, \code{sparer_pauschbetrag_tax_saved}.
    }
    \item{\code{buys}}{Benannter Vektor. Mittlere jährliche Käufe je Asset.}
    \item{\code{sells}}{Benannter Vektor. Mittlere jährliche Verkäufe je Asset.}
  }
}
\examples{
set.seed(42)
n <- 756  # 3 Jahre Handelstage
data <- data.frame(
  date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = n),
  MSCI = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012)),
  BOND =  50 * cumprod(1 + rnorm(n, 1e-4, 0.004))
)

strategy <- create_strategy(
  MSCI = asset_config("etf", action_type = "bnh",
                      asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
  BOND = asset_config("etf", action_type = "bnh",
                      asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0)
)

# Einfacher Lauf ohne Steuer
result <- simulation(data, strategy, start_value = 10000)
print(result)

# Mit Besteuerung, jährlichem Rebalancing und Risk-Free-Rate
result_tax <- simulation(
  data, strategy,
  start_value  = 10000,
  tax_mode     = "person",
  tax_rate     = 26.375,
  balance_mode = TRUE,
  balance_unit = "year",
  liquidate    = TRUE,
  risk_free    = 2
)
summary(result_tax)
}
\section{Terminverschiebung an aufgefüllten Tagen}{
  Geplante Ereignisse (DCA, periodisches Rebalancing, Splits, Liquidation,
  Asset-Starts), die auf einen per LOCF aufgefüllten Tag (Wochenende/Feiertag)
  fallen, werden automatisch auf den \strong{nächsten echten Handelstag}
  verschoben. Würde die Verschiebung den Monat verlassen (Monatsende), wird
  das Ereignis stattdessen auf den \strong{vorherigen} echten Handelstag
  \strong{vorgezogen}. Die \strong{Festsetzung} der Vorabpauschale bleibt
  kalendarisch am 31.12. (maßgeblich ist der letzte Rücknahmepreis des
  Jahres, per LOCF); ihre \strong{Begleichung} — Cash-Abzug bzw.
  Zwangsverkauf — erfolgt gemäß § 18 Abs. 3 InvStG am ersten Handelstag
  des Folgejahres zu dessen Kursen (Fallback: sofortige Zahlung, wenn die
  Simulation keinen weiteren Handelstag enthält). Die Vorabpauschale wird
  wie in der Bankpraxis mit dem allgemeinen § 20-Verlusttopf verrechnet
  (vor dem Sparer-Pauschbetrag); die T-2-Jahresenderstattung erfasst damit
  auch VP-Steuer bei später realisierten Verlusten.
}
\section{Signalbewusstes Rebalancing (Cash-Reserve-Modell)}{
  Die Rebalancing-Prozedur prüft die Signallogik eigenständig; der reguläre
  Signal-Trade-Block läuft an Rebalancing-Tagen nicht (keine Doppelorders).
  Signal-aktive und signal-inaktive Assets werden nach ihrem
  \strong{Zielgewicht gleichbehandelt}: Ein signalbedingt nicht investiertes (aber aktiviertes) Signal-Asset hält sein
  Zielgewicht als \strong{eigene Cash-Position} (jedes Asset besitzt ein
  eigenes Cash-Konto). Da Ist-Gewichte total-basiert sind (Kurswert + Cash),
  zählt die Reserve als Positionsgewicht; das Rebalancing gleicht sie über
  reine \strong{Cash-Transfers} mit dem Pool aus — der Pool wird also genau
  um den Betrag der inaktiven Assets reduziert, bevor der Rest investiert
  wird. Für Signal-Assets gilt am Rebalancing-Tag:
  \itemize{
    \item Position vorhanden + Verkaufssignal: vollständiger Signal-Exit;
      der Erlös wird zur Cash-Reserve des Assets.
    \item Keine Position + Kaufsignal: Signal-Entry aus der eigenen
      Cash-Reserve; danach normale Teilnahme am Gewichts-Rebalancing.
    \item Keine Position + kein Kaufsignal: die Cash-Reserve wird auf das
      Zielgewicht getrimmt (Auffüllen aus dem Pool bzw. Abschöpfen in den
      Pool), es findet aber \strong{kein Aktienkauf} statt.
    \item Andernfalls nimmt das Asset normal am Gewichts-Rebalancing teil.
  }
  Verbleibendes Cash der übrigen Assets (z. B. DCA-Zuflüsse am selben Tag)
  wird noch am Rebalancing-Tag reinvestiert; die Cash-Reserven signalbedingt wartender
  Signal-Assets bleiben davon unberührt.
}
\section{Ereignisbasiertes Rebalancing}{
  Zusammenspiel der Argumente:
  \describe{
    \item{\code{event_col}}{
      Character oder \code{NULL}. Name einer logischen Spalte in \code{data},
      die ereignisbasiertes Rebalancing auslöst (\code{TRUE} = Rebalancing-Tag).
      Erzeugt mit \code{\link{compute_rebal_trigger}}.
    }
    \item{\code{event_mode}}{
      \code{"additional"} (zusätzlich zu periodischem Rebalancing) oder
      \code{"replace"} (ersetzt periodisches Rebalancing).
    }
    \item{\code{event_weight}}{
      Benannte Liste oder \code{NULL}. Zielgewichte für event-Rebalancing.
    }
    \item{\code{start_date}, \code{stopp_date}}{
      Date oder \code{NULL}. Simulation auf einen Teilbereich einschränken.
    }
  }
}
\seealso{
  \code{\link{asset_config}}, \code{\link{create_strategy}},
  \code{\link{compute_rebal_trigger}}, \code{\link{plot.SimLevResult}}
}
