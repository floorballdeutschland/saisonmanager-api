# Be sure to restart your server when you modify this file.

# Configure parameters to be filtered from the log file. Use this to limit dissemination of
# sensitive information. See the ActiveSupport::ParameterFilter documentation for supported
# notations and behaviors.
# `code` deckt zwei Geheimnisse ab, die als gewoehnlicher Parameter ankommen:
# den OAuth-Anmeldecode fuer den YouTube-Zugang (er bleibt rund zehn Minuten
# einloesbar, wenn das Einloesen scheitert) und den Kurzcode des
# Spielsekretariats aus der Adresszeile. Die Filterung trifft als Teilstring
# auch `penalty_code_id` und Verwandte -- deren Werte im Log zu verlieren ist
# der guenstigere Tausch.
Rails.application.config.filter_parameters += %i[
  passw secret token _key crypt salt certificate otp ssn code
]
