# frozen_string_literal: true

module Seaports
  VERSION = "1.3.1"

  # The UN/LOCODE edition the shipped table was built from, when the source
  # names one: UNECE labels each release by year and half, so "2024-2" is the
  # second release of 2024. Nil when it does not, which is the normal case
  # while the mirror builds from UNECE's unnumbered pre-release file.
  DATA_RELEASE = nil

  # The day a refresh last changed the shipped table. A gem version says what
  # the code does; this says how old the data is, which is the question a
  # caller actually has, and it can be answered whatever the source publishes.
  DATA_REFRESHED_ON = "2026-11-02"
end
