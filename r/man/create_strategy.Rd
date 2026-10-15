\encoding{UTF-8}
\name{create_strategy}
\alias{create_strategy}
\alias{validate_strategy}
\alias{add_asset}
\alias{update_asset}
\alias{remove_asset}
\alias{migrate_strategy}
\alias{as_list}
\alias{as_list.strategy}
\alias{as_list.default}
\alias{print.strategy}
\alias{summary.strategy}
\title{Strategie-Objekte erstellen und verwalten}
\description{
  Funktionen zum Erstellen, Validieren und Bearbeiten von
  \code{"strategy"}-Objekten. Eine Strategie ist eine benannte Liste von
  \code{\link{asset_config}}-Konfigurationen, die an \code{\link{simulation}}
  übergeben wird.
}
\usage{
create_strategy(..., assets = NULL)

validate_strategy(strategy, data = NULL)

add_asset(strategy, name, asset)

update_asset(strategy, name, ...)

remove_asset(strategy, name)

migrate_strategy(old_strategy, verbose = TRUE)

as_list(x, ...)

\method{print}{strategy}(x, ...)
\method{summary}{strategy}(object, ...)
}
\arguments{
  \item{...}{
    Für \code{create_strategy}: benannte \code{\link{asset_config}}-Objekte
    (z. B. \code{SPY = asset_config(...)}); einfache Listen werden über
    \code{asset_config} umgewandelt und geprüft. Jeder Name darf nur einmal
    vorkommen (sonst Fehler).
    Für \code{update_asset}: benannte Felder, die im Asset aktualisiert werden.
    Für \code{as_list}, \code{print}, \code{summary}: ignoriert.
  }
  \item{assets}{
    Benannte Liste von \code{asset_config}-Objekten oder \code{NULL}. Alternative
    zu \code{...} für programmatische Nutzung (nicht beides zugleich).
    Standard: \code{NULL}.
  }
  \item{strategy}{Ein \code{"strategy"}-Objekt.}
  \item{data}{
    \code{data.frame} oder \code{NULL}. Falls angegeben, prüft
    \code{validate_strategy} ob alle Asset-Spalten und Signal-Spalten
    in \code{data} vorhanden sind.
  }
  \item{name}{Character. Name des Assets (muss Spalte in \code{data} entsprechen).}
  \item{asset}{Ein \code{\link{asset_config}}-Objekt.}
  \item{old_strategy}{
    Alte Listen-Strategie (vor S3-Klassen-Einführung) zur Migration.
  }
  \item{verbose}{Logisch. Migrations-Meldungen ausgeben? Standard: \code{TRUE}.}
  \item{x, object}{Ein \code{"strategy"}-Objekt.}
}
\value{
  \item{\code{create_strategy}}{Objekt der Klasse \code{"strategy"}.}
  \item{\code{validate_strategy}}{
    \code{TRUE} wenn valide; sonst Fehler mit Beschreibung.
  }
  \item{\code{add_asset}, \code{update_asset}, \code{remove_asset}}{
    Aktualisiertes \code{"strategy"}-Objekt.
  }
  \item{\code{migrate_strategy}}{
    Konvertiertes \code{"strategy"}-Objekt.
  }
  \item{\code{as_list}}{
    Unklassifizierte benannte Liste (für Legacy-Schnittstellen).
  }
  \item{\code{print}, \code{summary}}{
    Ausgabe auf der Konsole; \code{x} bzw. \code{object} unsichtbar.
  }
}
\details{
  \code{create_strategy} normiert die Zielgewichte nicht, und auch
  \code{\link{simulation}} normiert sie nicht: Die \code{asset_share}-Werte
  (Anteile, je größer 0 und höchstens 1) müssen sich für die Simulation
  auf 1 summieren, sonst bricht \code{simulation} mit Fehler ab.
  \code{summary} weist auf eine abweichende Summe hin.

  \code{validate_strategy} prüft ohne \code{data}, ob \code{strategy} die
  Klasse \code{"strategy"} hat und jedes Element ein
  \code{asset_config}-Objekt ist (Wertebereiche prüft bereits
  \code{asset_config}). Mit \code{data}: zusätzlich, ob jede Asset-Spalte und
  bei \code{action_type = "signal"} die Signalspalten vorhanden sind.

  \code{update_asset} akzeptiert Felder als \code{name = wert}-Paare; nur
  Felder, die das Asset bereits hat, werden übernommen (unbekannte mit
  Warnung ignoriert). Das Asset wird danach mit \code{asset_config} neu
  geprüft; nicht angegebene Felder bleiben unverändert. Ändert sich
  \code{asset_class} oder \code{deliverable} und wird \code{tax_regime}
  nicht mit angegeben, wird ein bisher automatisch abgeleitetes
  \code{tax_regime} neu abgeleitet (z. B. \code{"certificate"} ->
  \code{"etf"}: \code{"investment_fund"}); ein abweichend gesetztes
  (explizites) \code{tax_regime} bleibt erhalten.

  \code{migrate_strategy} setzt die veralteten Klassen
  \code{"etn_deliverable"}/\code{"etn_standard"} in \code{"etn"} mit
  \code{deliverable = TRUE}/\code{FALSE} um.

  \code{as_list} entfernt das \code{"strategy"}-Klassenattribut und gibt eine
  einfache Liste zurück — nützlich für Systeme, die keine S3-Objekte erwarten.
}
\examples{
# Zwei-Asset-Strategie
strategy <- create_strategy(
  MSCI = asset_config("etf", action_type = "bnh",
                      asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
  BOND = asset_config("etf", action_type = "bnh",
                      asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0)
)
print(strategy)
summary(strategy)

# Asset hinzufuegen / aktualisieren / entfernen
strategy <- add_asset(
  strategy, "GOLD",
  asset_config("etc", action_type = "bnh", asset_share = 0.1,
               deliverable = TRUE)
)
strategy <- update_asset(strategy, "MSCI", asset_share = 0.60)
strategy <- remove_asset(strategy, "GOLD")

# Validierung gegen Daten
set.seed(1)
data <- data.frame(
  date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 200),
  MSCI = 100 * cumprod(1 + rnorm(200, 4e-4, 0.012)),
  BOND =  50 * cumprod(1 + rnorm(200, 1e-4, 0.004))
)
validate_strategy(strategy, data)

# Als plain list (Legacy)
lst <- as_list(strategy)
}
\seealso{
  \code{\link{asset_config}}, \code{\link{simulation}}
}
