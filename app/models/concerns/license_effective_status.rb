# frozen_string_literal: true

# Status eines Lizenz-Hashes aus Player#licenses.
#
# Zwei Fragen, die auseinandergehalten werden muessen:
#
# * `current_status_id` -- was zuletzt gesetzt wurde.
# * `base_status_id`  -- welcher Status ohne Sperre gelten wuerde.
#
# Der Unterschied entsteht, weil eine Mannschaft ueber Team#cup_leagues auch an
# ihren Pokalligen haengt: EINE Lizenz erscheint dadurch in der Lizenzliste der
# Liga und in der des Pokals. Ein einzelner Statuswert in der History kann diese
# beiden Wettbewerbe nicht getrennt bedienen. Deshalb ist der gespeicherte
# Status die Grundlage und der Sperrzustand kommt aus `player_suspensions`
# dazu -- je Liga ausgewertet (#605).
#
# Gelesen wird ueber den Zeitstempel und nicht ueber die Position im Array:
# Angehaengt wird die History an vielen Stellen, sortiert ist sie nirgends
# garantiert.
module LicenseEffectiveStatus
  module_function

  def current_entry(license)
    Array(license && license['history']).max_by { |h| h['created_at'].to_s }
  end

  def current_status_id(license)
    current_entry(license)&.dig('license_status_id').to_i
  end

  # Der jüngste Eintrag, der keine Sperre ist. Fuer eine Lizenz ohne Sperre in
  # der History ist das derselbe Eintrag wie `current_entry`.
  def base_entry(license)
    Array(license && license['history'])
      .reject { |h| h['license_status_id'].to_i == License::SUSPENDED }
      .max_by { |h| h['created_at'].to_s }
  end

  def base_status_id(license)
    base_entry(license)&.dig('license_status_id').to_i
  end

  # Wuerde diese Lizenz ohne Sperre Spielberechtigung geben?
  #
  # Bewusst nur `erteilt`: Ein beantragter Antrag berechtigt nicht zum Einsatz,
  # zaehlt also auch kein Spiel einer Sperre ab.
  def eligible?(license)
    base_status_id(license) == License::APPROVED
  end
end
