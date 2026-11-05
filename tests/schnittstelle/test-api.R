# test-api.R
# Öffentliche Schnittstelle gegen den eingefrorenen Stand (bis 1.4.0 test-api-frozen.R).
#
# Führt den R-Auszug tests/schnittstelle/api_r.R mit --frozen-check aus: NAMESPACE und die Quellen r/R/*.R werden
# geparst und mit tests/schnittstelle/frozen/r.json verglichen (Funktionen und S3-Methoden, Argumente in Reihenfolge,
# Art, Standardwerte). Die Meldung nennt jede Abweichung und wie man den Stand bewusst neu festschreibt
# (Eintrag in tests/schnittstelle/CHANGES.md, dann tests/schnittstelle/run.py --freeze).
testthat::local_edition(3)   # Edition 3 wie bisher (Config/testthat/edition in r/DESCRIPTION entfällt)

test_that("Schnittstelle entspricht tests/schnittstelle/frozen/r.json", {
  root <- normalizePath(file.path(test_path(), "..", ".."), mustWork = FALSE)
  frozen <- file.path(root, "tests", "schnittstelle", "frozen", "r.json")
  script <- file.path(root, "tests", "schnittstelle", "api_r.R")
  expect_true(file.exists(frozen) && file.exists(script) && file.exists(file.path(root, "r", "NAMESPACE")))
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
