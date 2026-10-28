\encoding{UTF-8}
\name{wrapper_config}
\alias{wrapper_config}
\alias{print.SimLevWrapperConfig}
\title{Fonds-Wrapper: Zertifikat oder Fonds über eine innere Strategie}
\description{
  Beschreibt einen Fonds-Wrapper: Innen handelt eine eigene Strategie (mit
  Umschichten, Signalen und Ordergebühren), es fallen Verwaltungs- und
  Performancegebühr an. Außen ist der Wrapper \strong{ein} Asset der Strategie:
  \code{asset_config(..., wrapper = wrapper_config(...))}. Der Anleger kauft und
  verkauft Anteile mit eigenem Spread und eigenen Order- und Sparplangebühren
  und zahlt Steuern wie auf ein Einzelpapier (nach \code{asset_class} bzw.
  \code{tax_regime}). \code{\link{simulation}} rechnet dafür je Lauf den
  Anteilswert mit \code{\link{wrapper_nav}}.
}
\usage{
wrapper_config(strategy, rebalance = NULL, costs = funds_costs(),
               order_fee = NULL, volume = NULL)

\method{print}{SimLevWrapperConfig}(x, ...)
}
\arguments{
  \item{strategy}{
    Innere Strategie: Objekt aus \code{\link{create_strategy}} oder eine
    benannte Liste, die \code{create_strategy(assets = )} annimmt. Die Namen sind
    Kursspalten in \code{data}. Kein inneres Asset darf selbst einen Wrapper haben
    (Fehler). Innere Signale (\code{trading = "signal"}) sind erlaubt und beziehen
    sich auf Spalten in \code{data}. Die Gewichte (\code{share}) müssen sich auf 1
    summieren. Innere Spreads gelten wie angegeben (Standard 0); Werte \eqn{> 0}
    ergeben beim Erzeugen einen Hinweis mit der Liste der Assets.
  }
  \item{rebalance}{
    \code{NULL} (kein Umschichten) oder ein Objekt aus \code{\link{rebalance_plan}}:
    Umschichten innerhalb des Wrappers.
  }
  \item{costs}{
    Objekt aus \code{\link{funds_costs}}: Verwaltungsgebühr \code{fee} in Prozent p. a.
    und Performancegebühr \code{performance_fee} in Prozent (Rechnung siehe
    \code{\link{wrapper_nav}}). Standard: \code{funds_costs()} (0,95 \% p. a., 5 \%).
  }
  \item{order_fee}{
    Ordergebühr der inneren Käufe und Verkäufe (beim Start und beim Umschichten), im
    Format von \code{\link{sim_costs}}: Zahl (EUR je Order) oder
    \code{list(fixed, percent, min, max)}. \code{NULL} = keine.
  }
  \item{volume}{
    \code{NULL} oder Fondsvolumen in EUR (eine Zahl \eqn{> 0}). Pflicht, sobald
    \code{order_fee} feste Beträge enthält (\code{fixed} oder \code{min} \eqn{> 0} bzw.
    \code{max} \eqn{< \infty}), sonst Fehler; reine Prozentgebühren gehen ohne
    \code{volume}. Die innere Rechnung startet mit \code{volume}, ohne Angabe mit 100.
    Einzahlungen der Anleger ändern das Fondsvolumen nicht.
  }
  \item{x}{Ein \code{SimLevWrapperConfig}.}
  \item{...}{Wird ignoriert.}
}
\value{
  Objekt der Klasse \code{SimLevWrapperConfig}: Liste mit \code{strategy} (geprüft,
  Klasse \code{strategy}), \code{rebalance}, \code{costs}, \code{order_fee} (wie
  übergeben) und \code{volume}. \code{print} zeigt innere Assets, Umschichten,
  Kosten, Ordergebühr und Volumen und liefert \code{x} unsichtbar zurück.
}
\details{
  \strong{Steuerliche Einordnung.} Ob ein konkreter Wrapper steuerlich ein
  Investmentfonds (\code{tax_regime = "investment_fund"} mit \code{partial_exemption},
  Vorabpauschale) oder eine Kapitalforderung ist (\code{asset_class = "certificate"}:
  Besteuerung erst beim Verkauf, ohne Vorabpauschale und Teilfreistellung), entscheidet
  der Nutzer über \code{asset_class}/\code{tax_regime} des äußeren Assets; der Code legt
  das nicht fest.

  \strong{Performancegebühr.} Die Rechnung folgt den Leitlinien der ESMA zu
  Performancegebühren (tägliche Abgrenzung bei jeder Berechnung des Anteilswerts,
  Festschreibung höchstens einmal jährlich, High-Water-Mark über die ganze Laufzeit).
  Diese Leitlinien gelten für OGAW. Bei Zertifikaten gelten die Emissionsbedingungen
  des Produkts; der Nutzer prüft, ob die Rechnung dazu passt.

  \strong{Kleines Volumen.} Mindestbeträge der Engine (z. B. entfallen Umschichtungen
  unter 0,01 EUR) beziehen sich innen auf das Volumen (ohne \code{volume} 100). Für eine
  genaue Übereinstimmung mit der direkt gehaltenen Strategie \code{volume} in der Größe
  des Depots angeben.

  Mit Wrapper-Assets sind keine äußeren Signale möglich (\code{trading = "bnh"}).
}
\examples{
set.seed(1)
d <- data.frame(date = seq.Date(as.Date("2020-01-01"), by = "day", length.out = 730))
d$Welt <- 100 * cumprod(1 + rnorm(730, 3e-4, 0.01))
d$Gold <- 50 * cumprod(1 + rnorm(730, 1e-4, 0.008))
w <- wrapper_config(create_strategy(Welt = asset_config("etf", share = 0.7),
                                    Gold = asset_config("etc", share = 0.3)),
                    rebalance = rebalance_plan(unit = "quarter"),
                    costs = funds_costs(fee = 0.95, performance_fee = 10))
w
s <- create_strategy(Zertifikat = asset_config("certificate", spread = 0.5, wrapper = w))
r <- simulation(d, s, tax = tax_profile(church_tax = 8), liquidate = TRUE)
r$tax_report$total_taxes_paid
}
\seealso{
  \code{\link{wrapper_nav}}, \code{\link{asset_config}}, \code{\link{funds_costs}},
  \code{\link{simulation}} (Abschnitt Fonds-Wrapper)
}
