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
  trading  = c("bnh", "signal"),
  share  = 1.0,
  spread = 0,
  partial_exemption  = 0.0,
  deliverable  = FALSE,
  start  = NULL,
  tax_regime   = NULL,
  signal_buy   = NULL,
  signal_sell  = NULL,
  wrapper      = NULL
)
\method{print}{asset_config}(x, ...)
\method{summary}{asset_config}(object, ...)
}
\arguments{
  \item{asset_class}{
    Character. Assetklasse. Zulässig: \code{"etf"} (Standard), \code{"etn"},
    \code{"etc"}, \code{"certificate"} sowie die veralteten Werte
    \code{"etn_standard"} und \code{"etn_deliverable"}, die mit Warnung in
    \code{"etn"} mit \code{deliverable = FALSE} bzw. \code{TRUE} umgesetzt
    werden.
  }
  \item{trading}{
    Character. Handelsstrategie: \code{"bnh"} (Buy-and-Hold) oder
    \code{"signal"} (signalgesteuert). Bei \code{"signal"} steuern die
    Signalspalten nur Ein- und Ausstieg: Ohne Bestand wartet das Geld des
    Assets als Cash auf das Kaufsignal; hält das Asset Stücke (Position offen),
    wird neues Geld (Sparraten, Restcash, Umverteilungen) sofort angelegt wie
    bei Buy-and-Hold (nicht am Tag eines Verkaufssignals), unabhängig von
    \code{balance_mode}. Standard: \code{"bnh"}.
  }
  \item{share}{
    Numerisch (keine Zeichenkette). Zielgewicht des Assets im Portfolio \strong{als Anteil}
    (größer 0 und höchstens 1, z. B. \code{0.6} = 60 \%). Es wird nicht
    normiert: \code{\link{simulation}} verlangt, dass sich die Gewichte aller
    Assets auf 1 summieren. Standard: \code{1}.
  }
  \item{spread}{
    Numerisch. Voller Bid-Ask-Spread \strong{in Prozent} (z. B. \code{0.1}
    = 0,1 \%), nicht negativ. Pro Seite wird der halbe Spread angewandt.
    Standard: \code{0} (ohne Spread; wer Spreads abbilden will, gibt sie an).
  }
  \item{partial_exemption}{
    Numerisch. Teilfreistellungssatz nach § 20 Abs. 1 InvStG
    \strong{in Prozent} (0 bis 100; z. B. \code{30} für Aktien-ETFs,
    \code{15} für Mischfonds). Wirkt nur im Regime
    \code{"investment_fund"}. Werte zwischen 0 und 1 (vermutlich ein Anteil
    statt Prozent, z. B. \code{0.3}) werden mit Warnung angenommen.
    Standard: \code{0}.
  }
  \item{start}{
    Date, Character (\code{"JJJJ-MM-TT"}) oder \code{NULL}. Frühestmögliches
    Kaufdatum für dieses Asset (für gestaffelte Asset-Starts); wird als
    \code{Date} gespeichert, ein ungültiges Datum führt zu einem Fehler. In
    \code{\link{simulation}} erhält das Asset ab diesem Tag sein volles
    Zielgewicht \code{share}: Am Starttag wird immer auf die
    Zielgewichte umgeschichtet (Verkauf der übrigen Assets, Erstkauf des neuen
    Assets; mit Steuern, Spreads und Gebühren wie bei jedem Rebalancing), auch
    ohne \code{balance_mode}; ein zusätzlicher Handelsblock läuft an diesem
    Tag nicht. Mit \code{balance_mode = TRUE} gilt danach der normale
    Rhythmus, ohne \code{balance_mode} wird danach nicht mehr umgeschichtet
    (Sparraten nach Strategie-Gewichten).
    Standard: \code{NULL} (ab Simulationsbeginn).
  }
  \item{tax_regime}{
    Character oder \code{NULL}. Steuerregime: \code{"investment_fund"}
    (§§ 18–20 InvStG, ETFs), \code{"capital_gains"} (§ 20 EStG, keine VP),
    \code{"private_sale"} (§ 23 EStG, 1-Jahres-Frist). \code{NULL} = wird
    automatisch aus \code{asset_class} und \code{deliverable} abgeleitet.
    Andere Werte führen zu einem Fehler.
  }
  \item{deliverable}{
    Logisch. Physisch lieferbar (relevant für ETC/ETN: \code{TRUE} →
    \code{"private_sale"}-Regime wie Xetra-Gold)? Standard: \code{FALSE}.
  }
  \item{signal_buy}{
    Character oder \code{NULL}. Name der Spalte in \code{data} mit dem
    Kaufsignal (logisch, \code{TRUE} = kaufen). Bei
    \code{trading = "signal"} Pflicht (sonst Fehler).
  }
  \item{signal_sell}{
    Character oder \code{NULL}. Name der Spalte in \code{data} mit dem
    Verkaufssignal (logisch, \code{TRUE} = verkaufen). Bei
    \code{trading = "signal"} Pflicht (sonst Fehler).
  }
  \item{wrapper}{
    \code{NULL} oder ein Objekt aus \code{\link{wrapper_config}}: Das Asset ist dann
    ein Fonds-Wrapper (Zertifikat oder Fonds über eine innere Strategie). Sein Name
    ist \strong{keine} Kursspalte; \code{\link{simulation}} rechnet die Kurse als
    Anteilswert (\code{\link{wrapper_nav}}) aus den inneren Spalten. Eine Spalte
    gleichen Namens in \code{data} ist ein Fehler. Mit \code{wrapper} ist nur
    \code{trading = "bnh"} möglich (keine Signale auf den Anteilswert; Signale
    gehen in der inneren Strategie). Die äußeren Felder (\code{asset_class},
    \code{tax_regime}, \code{partial_exemption}, \code{spread}, \code{share},
    \code{start}) gelten für den Wrapper wie für ein Einzelpapier.
    Standard: \code{NULL} (kein Wrapper).
  }
  \item{x, object}{Ein \code{asset_config}-Objekt.}
  \item{...}{Wird ignoriert.}
}
\value{
  Objekt der Klasse \code{"asset_config"} (benannte Liste) mit den Feldern
  \code{asset_class}, \code{trading}, \code{share},
  \code{spread}, \code{partial_exemption}, \code{deliverable},
  \code{start}, \code{tax_regime}, \code{signal_buy},
  \code{signal_sell}, mit Wrapper zusätzlich \code{wrapper}; validiert und ggf.
  mit abgeleitetem \code{tax_regime}.
  Die Zahlen bleiben in den Einheiten der Eingabe (\code{share} als
  Anteil, \code{spread} und \code{partial_exemption} in Prozent).

  \code{print} und \code{summary} geben die Konfiguration auf der Konsole
  aus (mit Wrapper eine Zeile mit den inneren Assets und den Fondskosten) und
  liefern \code{x} unsichtbar zurück.
}
\details{
  Das \code{tax_regime} wird automatisch abgeleitet, wenn \code{NULL}:
  \itemize{
    \item \code{"etf"} → \code{"investment_fund"}
    \item \code{"etn"}, \code{"etc"}: \code{deliverable = TRUE} →
          \code{"private_sale"}; sonst \code{"capital_gains"}
    \item \code{"certificate"} → \code{"capital_gains"}
  }
  Der \code{spread} ist der \emph{volle} Bid-Ask-Spread; die Engine
  wendet den halben Spread je Seite an (Kauf: Briefkurs, Verkauf: Geldkurs).
}
\examples{
# ETF mit Teilfreistellung
etf <- asset_config(
  asset_class  = "etf",
  trading  = "bnh",
  share  = 0.6,
  spread = 0.1,
  partial_exemption  = 30
)
print(etf)

# Lieferbares ETC (physisches Gold) -> private_sale-Regime
gold <- asset_config(
  asset_class = "etc",
  trading = "bnh",
  share = 0.2,
  deliverable = TRUE
)
gold$tax_regime  # "private_sale"

# Signal-gesteuertes Asset
sig <- asset_config(
  asset_class  = "etf",
  trading  = "signal",
  share  = 1.0,
  spread = 0.1,
  partial_exemption  = 30,
  signal_buy   = "my_buy_col",
  signal_sell  = "my_sell_col"
)
}
\seealso{
  \code{\link{create_strategy}}, \code{\link{simulation}}, \code{\link{wrapper_config}}
}
