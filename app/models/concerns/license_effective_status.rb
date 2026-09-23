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
# garantiert. Unsortiert steht sie real im Altbestand und dort, wo Eintraege
# mit verschiedenem Offset aufeinandertreffen, vor allem nach Spieler-Merges
# zwischen #71 (08.07.2026) und #570 (27.08.2026), die noch als Text sortierten.
#
# Verglichen wird der Zeitpunkt, nicht die Zeichenkette. Die Eintraege tragen
# ihren Offset mit (`Time#as_json`), und `…T19:59+02:00` sortiert als Text
# hinter `…T18:25+00:00`, obwohl es der fruehere Zeitpunkt ist (17:59 UTC).
# Ein noch nicht gespeicherter Eintrag haelt ausserdem ein Time-Objekt statt
# einer Zeichenkette, dessen `to_s` (`2026-09-23 10:00:00 +0200`) als Text vor
# jedem ISO-Wert desselben Tages landet.
#
# Player#_merge_licenses sortiert ueber dieselbe `sort_key`, damit Merge und
# Lesen denselben Eintrag fuer den juengsten halten (#725).
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
  #
  # Die Zeichenkette als dritter Schluessel macht den Gleichstand stabil:
  # Derselbe Zeitpunkt mit anderem Offset entschiede sonst ueber die Position
  # im Array, und genau die soll nichts entscheiden.
  def sort_key(entry)
    time = parse_time(entry['created_at'])
    time ? [1, time.to_r, entry['created_at'].to_s] : [0, 0, entry['created_at'].to_s]
  end

  # Der Zeitpunkt eines Verlaufseintrags, oder nil, wenn er sich nicht
  # einordnen laesst.
  #
  # Der Formatriegel ist nicht kosmetisch. `Time.zone.parse` lehnt Bruchstuecke
  # nicht ab, sondern ERGAENZT sie aus dem heutigen Datum: "12x" wird zum 12.
  # des laufenden Monats, "18:25" zu heute um 18:25. Ein solcher Wert wirft
  # nichts, sieht gueltig aus und liegt naturgemaess ganz vorn -- er schluege
  # damit jede echte Erteilung.
  ISO_DATUM = /\A\d{4}-\d{2}-\d{2}/

  def parse_time(value)
    return value.to_time if value.respond_to?(:to_time) && !value.is_a?(String)
    return nil unless value.to_s.match?(ISO_DATUM)

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
