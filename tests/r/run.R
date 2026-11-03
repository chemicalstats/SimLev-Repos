# Tests des R-Pakets (T20: tests/r, gegen das installierte Paket; bis T20 r/tests/testthat):
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/r/run.R      (aus der Repo-Wurzel)
# Eingefrorene Schnittstelle, Steuerrecht, Engine und Entnahme mit von Hand belegten Werten, C-Bibliothek
# gegen unabhängige Werte, Grafiken sowie Prüfungen, die die Referenzfälle nicht erreichen. Den Gleichlauf mit
# Python und Julia prüfen die Referenzfälle tests/faelle (Tests der Ports) und tests/gleichlauf/run.sh.
# Die Tests laufen im Namensraum von SimLev (interne Funktionen ohne :::), wie unter R CMD check.
args <- commandArgs(FALSE)
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", args, value = TRUE)[1])))
suppressMessages(library(testthat))
res <- testthat::test_dir(here, package = "SimLev", load_package = "installed", stop_on_failure = TRUE)
