# test-api-frozen.R
# Öffentliche Schnittstelle gegen den eingefrorenen Stand (Etappe 6.6).
#
# Führt den R-Auszug tools/api_snapshot/api_r.R mit --frozen-check aus: NAMESPACE
# und die Quellen r/R/*.R werden geparst und mit tools/api_snapshot/frozen/r.json
# verglichen (Funktionen und S3-Methoden, Argumente in Reihenfolge, Art,
# Standardwerte). Die Meldung nennt jede Abweichung und wie man den Stand bewusst
# neu festschreibt (Eintrag in tools/api_snapshot/CHANGES.md, dann
# tools/api_snapshot/run.sh --freeze).
#
# Beim Prüfen eines gebauten Pakets (R CMD check) liegt das Repo nicht neben den
# Tests; dann wird der Test übersprungen. Die Gesamtprüfung macht dort
# tools/api_snapshot/run.sh --check.

test_that("Schnittstelle entspricht tools/api_snapshot/frozen/r.json", {
  root <- normalizePath(file.path(getwd(), "..", "..", ".."), mustWork = FALSE)
  frozen <- file.path(root, "tools", "api_snapshot", "frozen", "r.json")
  script <- file.path(root, "tools", "api_snapshot", "api_r.R")
  if (!file.exists(frozen) || !file.exists(script) || !file.exists(file.path(root, "r", "NAMESPACE")))
    skip(paste("tools/api_snapshot/frozen/r.json nicht erreichbar (gebautes Paket ohne Repo);",
               "Prüfung mit tools/api_snapshot/run.sh --check"))
  skip_if_not_installed("jsonlite")
  out <- tempfile("api_r_", fileext = ".json")
  on.exit(unlink(out), add = TRUE)
  old <- setwd(root)
  on.exit(setwd(old), add = TRUE)
  res <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"),
                                  c(shQuote(script), shQuote(out), "--frozen-check", shQuote(frozen)),
                                  stdout = TRUE, stderr = TRUE, env = "LC_ALL=C.UTF-8"))
  status <- attr(res, "status")
  ok <- is.null(status) || identical(as.integer(status), 0L)
  expect(ok, paste(c("", res), collapse = "\n"))
  if (ok) expect_true(any(grepl("entspricht dem eingefrorenen Stand", res)))
})
