\name{plot_interactive}
\encoding{UTF-8}
\alias{plot_interactive}
\alias{plot_interactive.SimLevResult}
\title{Interaktives Dashboard mit Hover-Tooltips}
\usage{
plot_interactive(x, ...)

\method{plot_interactive}{SimLevResult}(
  x,
  file       = NULL,
  panels     = c("performance", "drawdown", "weights"),
  max_points = 6000,
  open       = interactive(),
  engine     = c("auto", "plotly", "html"),
  ...
)
}
\arguments{
  \item{x}{Ein \code{SimLevResult}-Objekt aus \code{\link{simulation}}.}
  \item{file}{Zieldatei (\code{.html}); \code{NULL} = temporäre Datei.}
  \item{panels}{Character-Vektor, ein oder mehrere Werte aus
    \code{"performance"} (Depotwert je Asset, Gesamt und Summe der
    Einzahlungen einschließlich Startwert in EUR, brutto vor Kaufkosten wie
    \code{x$invested}), \code{"drawdown"} (\code{x$drawdowns} in Prozent
    unter dem Höchststand; mit Sparplan zeitgewichtet) und
    \code{"weights"} (Ist-Gewichte in Prozent). Die Kopfzeile zeigt CAGR,
    Sharpe Ratio und maximalen Drawdown aus dem Ergebnis; mit Sparplan als
    „CAGR (geldgewichtet)" und „Max. Drawdown (zeitgewichtet)" beschriftet.
    Standard: alle drei.}
  \item{max_points}{Ganzzahl. Punkte pro Serie werden für die Darstellung
    gleichmäßig auf höchstens diesen Wert ausgedünnt (Render-Performance);
    der letzte Tag bleibt immer erhalten. Standard: \code{6000}.}
  \item{open}{Logisch. Datei nach dem Schreiben im Browser öffnen?
    Standard: \code{interactive()}. Nur beim HTML-Writer wirksam.}
  \item{engine}{\code{"auto"} nutzt \pkg{plotly}, sofern installiert, sonst
    den eingebauten abhängigkeitsfreien HTML-Writer; \code{"plotly"} oder
    \code{"html"} erzwingen die jeweilige Variante (\code{"plotly"} ohne
    installiertes \pkg{plotly}: Warnung und HTML-Writer). Mit \pkg{plotly}
    wird keine Datei geschrieben; \code{file} und \code{open} wirken dann
    nicht.}
  \item{...}{Derzeit ungenutzt.}
}
\value{
Beim eingebauten HTML-Writer unsichtbar der Pfad zur erzeugten HTML-Datei.
Bei \pkg{plotly} (\code{engine = "plotly"} oder \code{"auto"} mit
installiertem \pkg{plotly}) sichtbar das plotly-Objekt (\code{subplot}).
}
\description{
Erzeugt ein interaktives Dashboard: Beim Überfahren der Grafiken erscheinen
Datum und Werte aller Serien in einem Tooltip; ein Crosshair läuft synchron
über alle Panels, Serien lassen sich per Klick auf die Legende ein- und
ausblenden. Aufgefüllte (LOCF-)Tage werden im Tooltip gekennzeichnet.

Ohne installiertes \pkg{plotly} schreibt SimLev ein vollständig
\strong{eigenständiges} HTML (Inline-SVG + JavaScript, keinerlei
Abhängigkeiten), das offline in jedem Browser funktioniert.
}
\examples{
\dontrun{
r <- simulation(data, strategy, start_value = 10000)
plot_interactive(r)
plot_interactive(r, file = "backtest.html",
                 panels = c("performance", "drawdown"))
}
}
\seealso{\code{\link{plot.SimLevResult}} für die statische Variante.}
\keyword{hplot}
