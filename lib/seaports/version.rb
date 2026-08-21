# frozen_string_literal: true

module Seaports
  VERSION = "1.0.0"

  # The UN/LOCODE edition the shipped table was built from. UNECE republishes
  # twice a year and names each release by year and half — "2024-2" is the
  # second release of 2024. A gem version says what the code does; this says
  # how old the data is, which is the question a caller actually has.
  DATA_RELEASE = "2024-2"
end
