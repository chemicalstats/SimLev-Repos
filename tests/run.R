# Tests des R-Pakets (tests/ nach Zweck gegliedert, gegen das installierte Paket):
#   LC_ALL=C.UTF-8 R_LIBS=<R-Bibliothek mit SimLev> Rscript tests/run.R [methodik] [fehler] [ausgabe] [schnittstelle]
# Ohne Liste alle Gruppen (aus der Repo-Wurzel). Je Gruppe die testthat-Dateien tests/<gruppe>/test-*.R:
#   methodik       Steuerrecht, Tarif, Engine, Entnahme (FIFO), Kennzahlen mit Handrechnung bzw. Gesetz; C-Bibliothek
#                  gegen Testvektoren und analytische Lösungen (nur R: die Ports sichern die Szenarien von gleichlauf)
#   fehler         Eingabeprüfungen und Wege, die die Tabellen von tests/fehler/faelle nicht erreichen (R-eigen)
#   ausgabe        R-Grafik (Basisgrafik)
#   schnittstelle  Schnittstelle gegen tests/schnittstelle/frozen/r.json
# gleichlauf, fehler und ausgabe der Referenzfälle haben R als Herkunft der Erwartung; R prüft sie, indem
# tests/werkzeuge/erzeugen.sh sie Byte für Byte gleich neu erzeugt (bzw. tests/werkzeuge/gleichlauf/run.sh --full).
# Die Tests laufen im Namensraum von SimLev (interne Funktionen ohne :::), wie unter R CMD check.
args <- commandArgs(FALSE)
here <- dirname(normalizePath(sub("^--file=", "", grep("^--file=", args, value = TRUE)[1])))
alle <- c("methodik", "fehler", "ausgabe", "schnittstelle")
wahl <- commandArgs(TRUE)
if (!length(wahl)) wahl <- alle
if (length(bad <- setdiff(wahl, alle))) stop("tests/run.R: unbekannte Gruppe ", paste(bad, collapse = ", "))
suppressMessages(library(testthat))
for (g in wahl) {
  cat(sprintf("== %s\n", g))
  testthat::test_dir(file.path(here, g), package = "SimLev", load_package = "installed", stop_on_failure = TRUE)
}
