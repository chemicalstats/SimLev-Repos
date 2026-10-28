# Etappe 9 (Entwurf C.7): die alten Tests laufen nur mit SIMLEV_LEGACY_TESTS=1; ohne den Schalter
# prueft R CMD check die Rd-Beispiele und die Rauchprobe tests/etappe9-smoke.R. Die Testdateien
# unter testthat/ bleiben unveraendert.
if (identical(Sys.getenv("SIMLEV_LEGACY_TESTS"), "1")) {
  library(testthat)
  library(SimLev)
  test_check("SimLev")
} else {
  message("SimLev: Tests in Etappe 9 ausgesetzt (siehe DEVELOPING; SIMLEV_LEGACY_TESTS=1 fuehrt sie aus)")
}
