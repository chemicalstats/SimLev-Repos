# anlageklassen.R – erzeugt anlageklassen.csv, die synthetischen Beispieldaten des Haupt-README.
#
#   Rscript anlageklassen.R [zielordner]          (Standard: Ordner dieses Skripts bzw. Arbeitsordner)
#
# Vier Kursreihen (Start 100) an allen Werktagen Montag bis Freitag vom 03.01.2005 bis 31.12.2024:
#   AKTIEN     Aktien            S&P 500 Total Return Index        (ab Jan 1980)
#   ANLEIHEN   Anleihen          Barclays Capital Bond Composite US (ab Sep 1997)
#   ROHSTOFFE  Rohstoffe         S&P GSCI Total Return              (ab Jan 1980)
#   MFUTURES   Managed Futures   Barclay BTOP 50 Index              (ab Jan 1987)
#
# Quelle aller Kennzahlen (Indizes in USD, jeweils bis Dez 2011):
#   Abrams, R., Bhaduri, R., Flores, E. (2012). A Quantitative Analysis of Managed Futures for Plan
#   Sponsors, Endowments and Foundations: Lintner Revisited. CME Group, Mai 2012.
#   Exhibit 4: annualisierte Rendite (Annualized ROR) und Standardabweichung;
#   Exhibit 7: Korrelationsmatrix.
#
# Verfahren: tägliche Logrenditen aus einer multivariaten Normalverteilung (Zufall von R, set.seed(2005)).
# Die Stichprobe wird exakt auf die Zielwerte gebracht (Momentenanpassung): Mittelwert, Standardabweichung
# und Korrelation der Logrenditen über alle Tage entsprechen genau den Vorgaben. Die Rendite über die
# 20 Jahre ist damit die annualisierte Rendite der Quelle, die annualisierte Volatilität (Werktage je
# Jahr = Zahl der Tage / 20) deren Standardabweichung. Die Reihen sind keine Marktdaten: keine Krisen,
# keine Regime, keine dicken Ränder, keine Währung (die Kurse werden im README als EUR-Kurse behandelt).

ziel <- commandArgs(trailingOnly = TRUE)
ziel <- if (length(ziel)) ziel[1] else "."

assets <- c("AKTIEN", "ANLEIHEN", "ROHSTOFFE", "MFUTURES")
rendite <- c(11.06, 6.41, 6.32, 8.99) / 100       # Exhibit 4, Annualized ROR
vola    <- c(15.62, 3.45, 19.56, 10.47) / 100     # Exhibit 4, Annualized Standard Deviation
korr <- matrix(c(                                 # Exhibit 7
   1.00, -0.10,  0.17, -0.04,
  -0.10,  1.00, -0.03,  0.20,
   0.17, -0.03,  1.00,  0.12,
  -0.04,  0.20,  0.12,  1.00), 4, 4, dimnames = list(assets, assets))

tage <- seq(as.Date("2005-01-03"), as.Date("2024-12-31"), by = "day")
tage <- tage[!format(tage, "%u") %in% c("6", "7")]
n <- length(tage) - 1L                            # Renditen; der erste Tag ist der Startkurs 100
jahre <- 20
je_jahr <- n / jahre

mu    <- log1p(rendite) / je_jahr                 # Logrendite je Tag
sigma <- vola / sqrt(je_jahr)
ziel_cov <- diag(sigma) %*% korr %*% diag(sigma)

set.seed(2005)
z <- matrix(rnorm(n * 4), n, 4)
z <- sweep(z, 2, colMeans(z))
z <- z %*% solve(chol(cov(z)))                    # Stichprobe: Mittel 0, Kovarianz genau Einheitsmatrix
x <- z %*% chol(ziel_cov)
x <- sweep(x, 2, mu, "+")

kurse <- 100 * exp(rbind(0, apply(x, 2, cumsum)))
out <- data.frame(date = format(tage, "%Y-%m-%d"))
for (j in seq_along(assets)) out[[assets[j]]] <- sprintf("%.4f", kurse[, j])
write.csv(out, file.path(ziel, "anlageklassen.csv"), row.names = FALSE, quote = FALSE)
