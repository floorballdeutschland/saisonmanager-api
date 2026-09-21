# Be sure to restart your server when you modify this file.

# Configure parameters to be filtered from the log file. Use this to limit dissemination of
# sensitive information. See the ActiveSupport::ParameterFilter documentation for supported
# notations and behaviors.
Rails.application.config.filter_parameters += %i[
  passw secret token _key crypt salt certificate otp ssn
]

# `code` deckt zwei Geheimnisse ab, die als gewoehnlicher Parameter ankommen:
# den OAuth-Anmeldecode fuer den YouTube-Zugang (er bleibt rund zehn Minuten
# einloesbar, wenn das Einloesen scheitert) und den Kurzcode des
# Spielsekretariats aus der Adresszeile.
#
# ALS AUSDRUCK MIT WORTGRENZEN und nicht als Teilstring: Rails reicht diese
# Liste an `ActiveRecord::Base.filter_attributes` weiter. Ein blosses `code`
# faerbte deshalb JEDE Spalte mit „code" im Namen als [FILTERED] ein -- in der
# Konsole waehrend einer Stoerungsanalyse, in Sentry und in jeder
# Testausgabe. `penalty_code_id` bleibt so lesbar, weil der Unterstrich ein
# Wortzeichen ist und die Grenze erst davor liegt.
Rails.application.config.filter_parameters << /\bcode\b/
