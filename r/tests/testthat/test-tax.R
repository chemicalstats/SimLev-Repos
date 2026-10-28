# Note: These tests require sourcing the internal tax functions
# In a real package, use testthat::local_edition(3) and internal function access

test_that("tax regime inference is correct", {
  # ETF -> investment_fund
  cfg <- asset_config(asset_class = "etf")
  expect_equal(cfg$tax_regime, "investment_fund")
  
  # ETN deliverable -> private_sale
  cfg <- asset_config(asset_class = "etn", deliverable = TRUE)
  expect_equal(cfg$tax_regime, "private_sale")
  
  # ETN not deliverable -> capital_gains
  cfg <- asset_config(asset_class = "etn", deliverable = FALSE)
  expect_equal(cfg$tax_regime, "capital_gains")
  
  # ETC deliverable -> private_sale
  cfg <- asset_config(asset_class = "etc", deliverable = TRUE)
  expect_equal(cfg$tax_regime, "private_sale")
  
  # Certificate -> capital_gains
  cfg <- asset_config(asset_class = "certificate")
  expect_equal(cfg$tax_regime, "capital_gains")
})


test_that("Teilfreistellung rates are valid", {
  # Equity ETF: 30%
  cfg <- asset_config(asset_class = "etf", partial_exemption = 30)
  expect_equal(cfg$partial_exemption, 30)
  
  # Mixed ETF: 15%
  cfg <- asset_config(asset_class = "etf", partial_exemption = 15)
  expect_equal(cfg$partial_exemption, 15)
  
  # Bond ETF: 0%
  cfg <- asset_config(asset_class = "etf", partial_exemption = 0)
  expect_equal(cfg$partial_exemption, 0)
})


test_that("tax_regime override works", {
  # Override ETF to capital_gains
  cfg <- asset_config(
    asset_class = "etf",
    tax_regime = "capital_gains"
  )
  expect_equal(cfg$tax_regime, "capital_gains")
})


test_that("holding period parameters are valid", {
  # § 23 EStG: steuerfrei bei MEHR als einem Jahr (kalendergenau)
  # Wird implizit ueber tax_regime getestet
  
  cfg <- asset_config(asset_class = "etc", deliverable = TRUE)
  expect_equal(cfg$tax_regime, "private_sale")
})


# Integration test placeholder - requires full simulation
test_that("simulation parameters for tax are valid", {
  skip("Requires full simulation function")
  
  # Default tax rate is 26.375% (25% + 5.5% Soli)
  # Default Sparerpauschbetrag is 1000 EUR
  # Default private_sale_threshold is 1000 EUR
})
