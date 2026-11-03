# anlageklassen.R – erzeugt anlageklassen.csv, die synthetischen Beispieldaten des Haupt-README.
#
#   Rscript anlageklassen.R [zielordner]          (Standard: Ordner dieses Skripts bzw. Arbeitsordner)
#
# Vier Kursreihen (Start 100) an allen Werktagen Montag bis Freitag vom 03.01.2005 bis 31.12.2024:
#   AKTIEN     Aktien
#   ANLEIHEN   Anleihen
#   ROHSTOFFE  Rohstoffe
#   MFUTURES   Managed Futures (Trendfolge)
#
# Parameter: hypothetische Annahmen zur Konstruktion eines Beispieldatensatzes; Größenordnungen gelten
# als allgemein bekannt; kein Abbild realer Märkte. Rendite und Volatilität sind gerundete Werte p. a.
# (Gesamtrendite einschließlich Zins bzw. Ausschüttungen), die Korrelationen gerundete Werte.
#
# Verfahren: tägliche Logrenditen aus einer multivariaten Normalverteilung (Zufall von R, set.seed(2005)).
# Die Stichprobe wird exakt auf die Zielwerte gebracht (Momentenanpassung): Mittelwert, Standardabweichung
# und Korrelation der Logrenditen über alle Tage entsprechen genau den Vorgaben. Die Rendite über die
# 20 Jahre ist damit die angenommene Rendite p. a., die annualisierte Volatilität (Werktage je
# Jahr = Zahl der Tage / 20) die angenommene Volatilität. Die Reihen sind keine Marktdaten: keine Krisen,
# keine Regime, keine dicken Ränder, keine Währung (die Kurse werden im README als EUR-Kurse behandelt).

ziel <- commandArgs(trailingOnly = TRUE)
ziel <- if (length(ziel)) ziel[1] else "."

assets <- c("AKTIEN", "ANLEIHEN", "ROHSTOFFE", "MFUTURES")
rendite <- c(9, 5, 7, 8) / 100                    # Annahme: Rendite p. a.
vola    <- c(16, 6, 16, 10) / 100                 # Annahme: Volatilität p. a.
korr <- matrix(c(                                 # Annahme: Korrelation (positiv definit)
   1.00,  0.10,  0.05,  0.00,
   0.10,  1.00, -0.15, -0.05,
   0.05, -0.15,  1.00,  0.10,
   0.00, -0.05,  0.10,  1.00), 4, 4, dimnames = list(assets, assets))

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
