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
# garantiert. Der Spieler-Merge etwa haengt die History der Dublette hinter die
# des Masters (`existing['history'] + lic['history']`), der letzte Eintrag ist
# danach der juengste der Dublette, nicht der juengste insgesamt (#725).
#
# Verglichen wird der Zeitpunkt, nicht die Zeichenkette. Die Eintraege tragen
# ihren Offset mit (`Time#as_json`), und `…T23:59+02:00` sortiert als Text
# hinter `…T18:25+00:00`, obwohl es der fruehere Zeitpunkt ist. Ein noch nicht
# gespeicherter Eintrag haelt ausserdem ein Time-Objekt statt einer
# Zeichenkette, dessen `to_s` (`2026-09-23 10:00:00 +0200`) als Text vor jedem
# ISO-Wert landet.
module LicenseEffectiveStatus
  module_function

  def current_entry(license)
    Array(license && license['history']).max_by { |h| sort_key(h) }
  end

  def current_status_id(license)
    current_entry(license)&.dig('license_status_id').to_i
  end

  # Der jüngste Eintrag, der keine Sperre ist. Fuer eine Lizenz ohne Sperre in
  # der History ist das derselbe Eintrag wie `current_entry`.
  def base_entry(license)
    Array(license && license['history'])
      .reject { |h| h['license_status_id'].to_i == License::SUSPENDED }
      .max_by { |h| sort_key(h) }
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

  # Ein Eintrag ohne lesbaren Zeitstempel sortiert vor jeden lesbaren und
  # untereinander wie bisher als Text. Er darf nicht werfen: Im Altbestand
  # fehlt der Zeitstempel an einzelnen Eintraegen ganz.
  def sort_key(entry)
    time = entry_time(entry['created_at'])
    time ? [1, time.to_r] : [0, entry['created_at'].to_s]
  end

  def entry_time(value)
    return value.to_time if value.is_a?(Time) || value.is_a?(DateTime) || value.is_a?(ActiveSupport::TimeWithZone)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    begin
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
