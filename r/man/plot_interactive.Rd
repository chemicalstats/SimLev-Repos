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
  \item{panels}{Auswahl aus \code{"performance"} (Depotwert je Asset, Gesamt,
    kumulierte Einzahlungen), \code{"drawdown"} und \code{"weights"}
    (Ist-Gewichte in Prozent).}
  \item{max_points}{Punkte pro Serie werden für die Darstellung gleichmäßig
    auf höchstens diesen Wert ausgedünnt (Render-Performance).}
  \item{open}{Logisch. Datei nach dem Schreiben im Browser öffnen?}
  \item{engine}{\code{"auto"} nutzt \pkg{plotly}, sofern installiert, sonst
    den eingebauten abhängigkeitsfreien HTML-Writer; \code{"plotly"} oder
    \code{"html"} erzwingen die jeweilige Variante.}
  \item{...}{Derzeit ungenutzt.}
}
\value{
Unsichtbar der Pfad zur erzeugten HTML-Datei (bei \code{engine = "plotly"}
das plotly-Objekt).
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
