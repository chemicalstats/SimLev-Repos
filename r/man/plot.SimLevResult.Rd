\encoding{UTF-8}
\name{plot.SimLevResult}
\alias{plot.SimLevResult}
\alias{print.SimLevResult}
\alias{summary.SimLevResult}
\alias{export_dashboard}
\alias{export_html_dashboard}
\alias{SimLevResult}
\title{Ergebnisse visualisieren und exportieren}
\description{
  Methoden und Export-Funktionen für \code{"SimLevResult"}-Objekte, die von
  \code{\link{simulation}} zurückgegeben werden.

  \code{plot} erstellt ein mehrteiliges Dashboard-Layout mit wählbaren
  Panels (Performance, Drawdown, Renditeverteilung, Rolling Returns,
  Monats-Heatmap, Statistiken, Korrelation, Strategievergleich).

  \code{export_dashboard} speichert das Dashboard als PDF.

  \code{export_html_dashboard} erstellt ein interaktives HTML-Dashboard
  (benötigt das Paket \pkg{plotly}).
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

export_dashboard(
  x,
  filename = "dashboard.pdf",
  width    = 14,
  height   = 10,
  ...
)

export_html_dashboard(x, filename = "dashboard.html")
}
\arguments{
  \item{x, object}{Ein \code{"SimLevResult"}-Objekt.}
  \item{style}{
    Character. Dashboard-Stil:
    \describe{
      \item{\code{"full"}}{Alle verfügbaren Panels (Standard).}
      \item{\code{"compact"}}{4 Kern-Panels (Performance, Drawdown,
        Verteilung, Statistiken) im 2×2-Layout.}
      \item{\code{"custom"}}{Panels werden über \code{panels} festgelegt.}
    }
  }
  \item{panels}{
    Character-Vektor. Welche Panels angezeigt werden sollen (nur bei
    \code{style = "custom"}). Mögliche Werte: \code{"performance"},
    \code{"drawdown"}, \code{"distribution"}, \code{"rolling"},
    \code{"monthly"}, \code{"stats"}, \code{"correlation"},
    \code{"comparison"}.
  }
  \item{compare}{
    \code{"SimLevResult"} oder \code{NULL}. Zweites Ergebnisobjekt für
    einen Strategievergleich.
  }
  \item{colors}{
    Benannte Liste oder \code{NULL}. Farbschema mit Elementen:
    \code{primary}, \code{secondary}, \code{positive}, \code{negative},
    \code{neutral}, \code{background}, \code{grid}.
    \code{NULL} = Standard-Farbschema.
  }
  \item{filename}{Character. Pfad der Ausgabedatei.}
  \item{width}{Numerisch. Breite in Zoll. Standard: \code{14}.}
  \item{height}{Numerisch. Höhe in Zoll. Standard: \code{10}.}
  \item{...}{
    Für \code{plot}: wird ignoriert.
    Für \code{export_dashboard}: wird an \code{plot.SimLevResult}
    weitergeleitet.
  }
}
\value{
  \item{\code{plot.SimLevResult}}{Unsichtbar \code{NULL} (Seiteneffekt: Plot).}
  \item{\code{print.SimLevResult}}{Unsichtbar \code{x}.}
  \item{\code{summary.SimLevResult}}{Unsichtbar \code{x}.}
  \item{\code{export_dashboard}}{Unsichtbar \code{NULL} (Datei wird geschrieben).}
  \item{\code{export_html_dashboard}}{Unsichtbar \code{NULL} (Datei wird geschrieben).}
}
\examples{
set.seed(7)
n <- 500
data <- data.frame(
  date = seq.Date(as.Date("2021-01-01"), by = "day", length.out = n),
  ETF  = 100 * cumprod(1 + rnorm(n, 4e-4, 0.012))
)
strategy <- create_strategy(
  ETF = asset_config("etf", action_type = "bnh",
                     asset_share = 1, asset_spread = 0.1, asset_bonus = 30)
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

# Als HTML exportieren (benötigt plotly)
export_html_dashboard(result, "bericht.html")

# Zwei Strategien vergleichen
result2 <- simulation(data, strategy, start_value = 10000,
                      balance_mode = TRUE, balance_unit = "year")
plot(result, compare = result2)
}
}
\seealso{
  \code{\link{simulation}}, \code{\link{create_strategy}}
}
