\encoding{UTF-8}
\name{plot.SimLevResult}
\alias{plot.SimLevResult}
\alias{print.SimLevResult}
\alias{summary.SimLevResult}
\alias{print.summary.SimLevResult}
\alias{export_dashboard}
\alias{SimLevResult}
\title{Ergebnisse visualisieren und exportieren}
\description{
  Methoden und Export-Funktionen für \code{"SimLevResult"}-Objekte, die von
  \code{\link{simulation}} zurückgegeben werden.

  \code{plot} erstellt ein mehrteiliges Dashboard-Layout mit wählbaren
  Panels (Wertentwicklung, Drawdown, Renditeverteilung, rollierende Renditen,
  Monatsrenditen-Heatmap, Kennzahlen, Korrelation, Strategievergleich).
  Korrelation und Strategievergleich gibt es nur mit \code{compare}.

  \code{export_dashboard} speichert das Dashboard als PDF.

  \code{print} gibt die wichtigsten Kennzahlen und ggf. die
  Steuerzusammenfassung auf der Konsole aus. \code{summary} liefert eine
  Liste der Klasse \code{"summary.SimLevResult"} und druckt nicht selbst;
  ihre Methode \code{print} zeigt die kompakte Kennzahlentabelle (in der
  Konsole erscheint sie bei \code{summary(x)} wie bisher, bei
  \code{s <- summary(x)} erst mit \code{print(s)} bzw. \code{s}).
}
\usage{
\method{plot}{SimLevResult}(
  x,
  style  = c("full", "compact", "custom"),
  panels = c("performance", "drawdown", "distribution",
             "rolling", "monthly", "stats"),
  compare = NULL,
  colors  = NULL,
  ...
)

\method{print}{SimLevResult}(x, ...)

\method{summary}{SimLevResult}(object, ...)

\method{print}{summary.SimLevResult}(x, ...)

export_dashboard(
  x,
  filename = "dashboard.pdf",
  width    = 14,
  height   = 10,
  ...
)
}
\arguments{
  \item{x, object}{Ein \code{"SimLevResult"}-Objekt (bei
    \code{print.summary.SimLevResult}: das Ergebnis von \code{summary}).}
  \item{style}{
    Character. Dashboard-Stil:
    \describe{
      \item{\code{"full"}}{Standard. Ohne \code{compare} 6 Panels
        (Wertentwicklung, Drawdown, Verteilung, rollierende Renditen, Monats-Heatmap,
        Kennzahlen) im 3×2-Layout; mit \code{compare} zusätzlich
        Korrelation (rollierende Korrelation der bereinigten Tagesrenditen
        von \code{x} und \code{compare} über 252 Beobachtungen, bei kurzer
        Historie ein Viertel der Tage, ohne aufgefüllte Tage; dazu die
        Gesamtkorrelation als Linie und Text) und Strategievergleich
        (8 Panels, 4×2).}
      \item{\code{"compact"}}{4 Kern-Panels (Wertentwicklung, Drawdown,
        Verteilung, Kennzahlen) im 2×2-Layout.}
      \item{\code{"custom"}}{Panels werden über \code{panels} festgelegt;
        ein oder zwei Panels nebeneinander, sonst zwei Spalten mit bis zu
        vier Zeilen (bei ungerader Anzahl bleibt das letzte Feld leer).}
    }
  }
  \item{panels}{
    Character-Vektor. Welche Panels angezeigt werden sollen (nur bei
    \code{style = "custom"}; bei anderem \code{style} wird ein angegebenes
    \code{panels} mit Warnung ignoriert). Mögliche Werte:
    \code{"performance"}, \code{"drawdown"}, \code{"distribution"},
    \code{"rolling"}, \code{"monthly"}, \code{"stats"},
    \code{"correlation"}, \code{"comparison"}; eindeutige Abkürzungen
    sind erlaubt, doppelte Einträge zählen einmal, unbekannte Namen (z. B.
    Tippfehler) sind ein Fehler. Die Panels erscheinen in der obigen
    Reihenfolge, nicht in der Reihenfolge von \code{panels}.
    \code{"correlation"} und \code{"comparison"} benötigen \code{compare};
    ohne \code{compare} werden sie mit Warnung weggelassen (bleibt kein
    Panel übrig, erscheint ein Hinweisfeld).
  }
  \item{compare}{
    \code{"SimLevResult"} oder \code{NULL}. Zweites Ergebnisobjekt für
    einen Strategievergleich; es wird über die Datumsachse von \code{x}
    gezeichnet und muss daher dieselben Tage (gleiche Länge) haben, sonst
    bricht \code{plot} mit einer Meldung ab.
  }
  \item{colors}{
    Benannte Liste oder \code{NULL}. Farbschema mit Elementen:
    \code{primary}, \code{secondary}, \code{positive}, \code{negative},
    \code{neutral}, \code{background}, \code{grid}; je Element eine
    Farbe, die \code{\link[grDevices]{col2rgb}} versteht: R-Farbname (z. B.
    \code{"navy"}, siehe \code{\link[grDevices]{colors}}) oder Hex-Code
    \code{"#RRGGBB"} bzw. \code{"#RRGGBBAA"}. Ungültige Farbwerte sind ein
    Fehler mit Nennung des Elements. Flächen und Histogramm erhalten ihre
    Transparenz über \code{\link[grDevices]{adjustcolor}}. Nicht angegebene
    Elemente werden aus dem Standard-Farbschema ergänzt (z. B.
    \code{list(primary = "#003366")}); unbekannte Namen sind ein Fehler.
    \code{NULL} = Standard-Farbschema.
  }
  \item{filename}{Character. Pfad der Ausgabedatei. Standard:
    \code{"dashboard.pdf"}.}
  \item{width}{Numerisch. Breite in Zoll. Standard: \code{14}.}
  \item{height}{Numerisch. Höhe in Zoll. Standard: \code{10}.}
  \item{...}{
    Für \code{plot}, \code{print}, \code{summary}: wird ignoriert.
    Für \code{export_dashboard}: wird an \code{plot.SimLevResult}
    weitergeleitet.
  }
}
\value{
  \item{\code{plot.SimLevResult}}{Unsichtbar \code{NULL} (Seiteneffekt: Plot).}
  \item{\code{print.SimLevResult}}{Unsichtbar \code{x}.}
  \item{\code{summary.SimLevResult}}{Sichtbar eine Liste der Klasse
    \code{"summary.SimLevResult"} mit \code{n_days}, \code{n_years},
    \code{start_value} (Depotwert am Starttag in EUR, nach Kaufkosten und mit
    der Sparrate des Starttags; Ausgabe \dQuote{Depotwert Starttag}),
    \code{start_capital} (Startkapital in EUR: Argument \code{start_value}
    von \code{\link{simulation}}, berechnet als \code{invested[1]} minus
    Einzahlungen des Starttags; \code{NA} ohne \code{invested}),
    \code{end_value}, \code{invested} (EUR; Startwert
    plus Einzahlungen, brutto), \code{total_return_twr} (zeitgewichtete
    Gesamtrendite: mit Sparplan letzter Wert von \code{twr_index} minus 1,
    sonst Endwert / Depotwert am Starttag - 1), \code{return_on_invested}
    ((Endwert - Eingezahlt) / Eingezahlt), \code{total_return}
    (gleichwertiger Alias für \code{total_return_twr}), \code{cagr},
    \code{ttwror} (Anteile; mit Sparplan ist \code{cagr} geldgewichtet),
    den Kennzahlen aus \code{statistics} (\code{sharpe}, \code{sortino},
    \code{calmar}, \code{omega}, \code{gain_to_pain}, \code{serenity},
    \code{martin_ratio}, \code{max_drawdown}, \code{average_drawdown},
    \code{ulcer_index}, \code{longest_drawdown}, \code{avg_recovery_time})
    sowie \code{statistics}, \code{tax_report} (einschließlich
    \code{open_tax_debt}, bei \code{tax_mode = "person"} \code{next_year},
    mit \code{taxable_income} \code{tariff_years}), \code{undefined_metrics}
    (Ursachen nicht definierter Kennzahlen, siehe \code{\link{simulation}})
    und \code{external_flows}.}
  \item{\code{print.summary.SimLevResult}}{Unsichtbar \code{x}; gibt die
    kompakte Zusammenfassung aus (nicht definierte Kennzahlen als
    \dQuote{nicht definiert (Ursache)}).}
  \item{\code{export_dashboard}}{Unsichtbar \code{NULL} (PDF-Datei wird geschrieben;
    das PDF-Gerät wird auch bei einem Fehler wieder geschlossen).}
}
\details{
  Die Kennzahlen des Dashboards entsprechen \code{x$statistics}: Die Sharpe
  Ratio ist \code{statistics$sharpe} (mit dem in \code{\link{simulation}}
  gewählten \code{risk_free}), die annualisierte Volatilität
  \code{statistics$sd} mal Wurzel der tatsächlichen Beobachtungen je Jahr
  (ohne aufgefüllte Tage, also rund 252 bei Handelstagsdaten und 365 bei
  Kalenderdaten). Alle Renditen sind um Einzahlungen (Sparplan) bereinigt:
  Die Verteilungsgrafik zeigt einfache Tagesrenditen in Prozent ohne
  aufgefüllte (LOCF-)Tage, die rollierenden Renditen werden kalendergenau
  annualisiert (Exponent 365,25 / Kalendertage des Fensters), die
  Monats-Heatmap zeigt Monatsrenditen von Monatsende zu Monatsende (erster
  Monat ab dem Starttag) in Prozent; die Farbskala reicht von -10 bis +10
  Prozent, stärkere Monate erhalten die Randfarbe (der Wert steht im Feld).
  Beträge werden in EUR beschriftet (Wertachse in Tsd. bzw. Mio., Einheit
  im Achsentitel; Endwert-Label mit drei gültigen Stellen, Kennzahlentabelle
  mit vollen Beträgen auf zwei Nachkommastellen). Die Ränder richten sich nach der Breite der
  Beschriftungen; Kennzahlentabelle und Strategievergleich verkleinern bei
  wenig Platz die Schrift (die Kennzahlen ggf. in zwei Spalten). Im
  Strategievergleich ist die Differenz Strategie 1 minus Strategie 2 grün,
  wenn Strategie 1 besser ist (bei Max. DD und Volatilität also kleiner),
  rot, wenn sie schlechter ist, und grau bei Gleichstand (auf zwei
  Nachkommastellen). Bei
  sehr kurzen Ergebnissen zeigen Panels ohne ausreichende Daten den Hinweis
  „Zu wenige Daten".

  \strong{Sparplan (Einzahlungen, \code{x$external_flows = TRUE}).} Die
  Wertgrafik zeigt weiterhin den Depotwert \code{x$worth} und zusätzlich
  die Summe der Einzahlungen (Startwert plus Sparraten, \code{x$invested})
  als gepunktete Linie. Drawdown-Grafik und Drawdown-Kennzahlen beruhen auf
  dem zeitgewichteten Wertindex \code{x$twr_index} (wie \code{x$drawdowns}),
  die CAGR ist geldgewichtet (interner Zinsfuß) und so beschriftet; die
  Gesamtrendite im Kennzahlen-Panel und im Vergleich ist zeitgewichtet, die
  Referenzlinie der rollierenden Renditen zeigt die TTWROR. \code{print}
  und \code{summary} kennzeichnen die CAGR als geldgewichtet, TTWROR,
  Gesamtrendite und Drawdowns als zeitgewichtet, nennen die eingezahlte
  Summe und weisen darauf hin, dass Calmar, Serenity und Martin Ratio dann
  mit der TTWROR rechnen. Ohne Einzahlungen bleiben Grafik und Ausgabe
  unverändert.
}
\examples{
set.seed(7)
n <- 500
data <- data.frame(
  date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n),
  ETF  = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012))
)
strategy <- create_strategy(
  ETF = asset_config("etf", trading = "bnh",
                     share = 1, spread = 0.1, partial_exemption = 30)
)
result <- simulation(data, strategy, start_value = 10000)

# Standard-Dashboard
\dontrun{
plot(result)

# Kompaktes Dashboard
plot(result, style = "compact")

# Benutzerdefinierte Panels
plot(result, style = "custom",
     panels = c("performance", "drawdown", "stats"))

# Eigenes Farbschema
plot(result, colors = list(
  primary    = "#003366",
  secondary  = "#FFB81C",
  positive   = "#00A651",
  negative   = "#ED1C24",
  neutral    = "#666666",
  background = "#FFFFFF",
  grid       = "#CCCCCC"
))

# Als PDF exportieren
export_dashboard(result, "bericht.pdf", width = 16, height = 10)

# Zwei Strategien vergleichen
result2 <- simulation(data, strategy, start_value = 10000, rebalance = rebalance_plan(unit = "year"))
plot(result, compare = result2)
}
}
\seealso{
  \code{\link{simulation}}, \code{\link{create_strategy}}
}
