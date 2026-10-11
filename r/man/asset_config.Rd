\encoding{UTF-8}
\name{asset_config}
\alias{asset_config}
\alias{print.asset_config}
\alias{summary.asset_config}
\title{Asset-Konfiguration erstellen}
\description{
  Erstellt und validiert die Konfiguration eines einzelnen Assets für die
  Simulation. Pflichtfelder werden geprüft, ungültige Werte sofort gemeldet.
  Das Ergebnis wird als \code{"asset_config"}-Objekt in
  \code{\link{create_strategy}} eingesetzt.
}
\usage{
asset_config(
  asset_class  = c("etf", "etn", "etc", "certificate",
                   "etn_standard", "etn_deliverable"),
  action_type  = c("bnh", "signal"),
  asset_share  = 1.0,
  asset_spread = 0.1,
  asset_bonus  = 0.0,
  deliverable  = FALSE,
  asset_start  = NULL,
  tax_regime   = NULL,
  signal_buy   = NULL,
  signal_sell  = NULL
)
\method{print}{asset_config}(x, ...)
\method{summary}{asset_config}(object, ...)
}
\arguments{
  \item{asset_class}{
    Character. Assetklasse. Zulässig: \code{"etf"}, \code{"etn"},
    \code{"etc"}, \code{"certificate"}, \code{"etn_standard"},
    \code{"etn_deliverable"}.
  }
  \item{action_type}{
    Character. Handelsstrategie: \code{"bnh"} (Buy-and-Hold) oder
    \code{"signal"} (signalgesteuert). Standard: \code{"bnh"}.
  }
  \item{asset_share}{
    Numerisch. Zielgewicht des Assets im Portfolio (positiv; wird vor der
    Simulation auf 1 normiert). Standard: \code{1}.
  }
  \item{asset_spread}{
    Numerisch. Voller Bid-Ask-Spread \strong{in Prozent} (z. B. \code{0.1}
    = 0,1 \%). Pro Seite wird der halbe Spread angewandt. Standard: \code{0.1}.
  }
  \item{asset_bonus}{
    Numerisch. Teilfreistellungssatz nach § 20 Abs. 1 InvStG
    \strong{in Prozent} (z. B. \code{30} für Aktien-ETFs, \code{15} für
    Mischfonds). Standard: \code{0}.
  }
  \item{asset_start}{
    Date, Character oder \code{NULL}. Frühestmögliches Kaufdatum für dieses
    Asset (für gestaffelte Asset-Starts). Standard: \code{NULL} (ab
    Simulationsbeginn).
  }
  \item{tax_regime}{
    Character oder \code{NULL}. Steuerregime: \code{"investment_fund"}
    (§§ 18–20 InvStG, ETFs), \code{"capital_gains"} (§ 20 EStG, keine VP),
    \code{"private_sale"} (§ 23 EStG, 1-Jahres-Frist). \code{NULL} = wird
    automatisch aus \code{asset_class} und \code{deliverable} abgeleitet.
  }
  \item{deliverable}{
    Logisch. Physisch lieferbar (relevant für ETC/ETN: \code{TRUE} →
    \code{"private_sale"}-Regime wie Xetra-Gold)? Standard: \code{FALSE}.
  }
  \item{signal_buy}{
    Character oder \code{NULL}. Name der Spalte in \code{data} mit dem
    Kaufsignal (logisch, \code{TRUE} = kaufen). Nur bei
    \code{action_type = "signal"} erforderlich.
  }
  \item{signal_sell}{
    Character oder \code{NULL}. Name der Spalte in \code{data} mit dem
    Verkaufssignal (logisch, \code{TRUE} = verkaufen). Nur bei
    \code{action_type = "signal"} erforderlich.
  }
  \item{x, object}{Ein \code{asset_config}-Objekt.}
  \item{...}{Wird ignoriert.}
}
\value{
  Objekt der Klasse \code{"asset_config"} (benannte Liste) mit allen
  übergebenen Feldern, validiert und ggf. mit abgeleitetem \code{tax_regime}.
}
\details{
  Das \code{tax_regime} wird automatisch abgeleitet, wenn \code{NULL}:
  \itemize{
    \item \code{"etf"} → \code{"investment_fund"}
    \item \code{"etn"}, \code{"etc"}: \code{deliverable = TRUE} →
          \code{"private_sale"}; sonst \code{"capital_gains"}
    \item \code{"certificate"} → \code{"capital_gains"}
  }
  Der \code{asset_spread} ist der \emph{volle} Bid-Ask-Spread; die Engine
  wendet den halben Spread je Seite an (Kauf: Briefkurs, Verkauf: Geldkurs).
}
\examples{
# ETF mit Teilfreistellung
etf <- asset_config(
  asset_class  = "etf",
  action_type  = "bnh",
  asset_share  = 0.6,
  asset_spread = 0.1,
  asset_bonus  = 30
)
print(etf)

# Lieferbares ETC (physisches Gold) -> private_sale-Regime
gold <- asset_config(
  asset_class = "etc",
  action_type = "bnh",
  asset_share = 0.2,
  deliverable = TRUE
)
gold$tax_regime  # "private_sale"

# Signal-gesteuertes Asset
sig <- asset_config(
  asset_class  = "etf",
  action_type  = "signal",
  asset_share  = 1.0,
  asset_spread = 0.1,
  asset_bonus  = 30,
  signal_buy   = "my_buy_col",
  signal_sell  = "my_sell_col"
)
}
\seealso{
  \code{\link{create_strategy}}, \code{\link{simulation}}
}
