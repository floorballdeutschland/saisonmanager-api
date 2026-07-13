# frozen_string_literal: true

module LegacyImport
  # Schließt offene Legacy-Vereinsmitgliedschaften eines Spielers.
  #
  # Legacy-Einträge aus dem Import 2010–2014 haben weder `created_at` noch
  # `valid_until` (= "bis heute" offen), obwohl der Spieler den Verein längst
  # verlassen hat. Diese Mitgliedschaft war zeitlich die erste; sie endet mit
  # dem Eintritt in den nächsten (datierten) Verein.
  #
  # Regel: `valid_until` der offenen Legacy-Mitgliedschaft = `created_at` des
  # frühesten datierten Folgeeintrags. Existiert kein datierter Folgeeintrag
  # (Spieler nie gewechselt), bleibt die Mitgliedschaft offen.
  module MembershipCloser
    module_function

    # clubs: Array der Player#clubs-Hashes. Gibt [neues_clubs_array, changed?]
    # zurück; das Eingabe-Array wird nicht mutiert.
    def close(clubs)
      clubs = Array(clubs)
      successor_start = earliest_dated_start(clubs)
      return [clubs, false] if successor_start.nil?

      changed = false
      new_clubs = clubs.map do |entry|
        if open_legacy?(entry)
          changed = true
          entry.merge('valid_until' => successor_start)
        else
          entry
        end
      end

      [new_clubs, changed]
    end

    # Offener Legacy-Eintrag: weder Beginn (created_at) noch Ende (valid_until).
    def open_legacy?(entry)
      entry['created_at'].blank? && entry['valid_until'].blank? && entry['club_id'].present?
    end

    # created_at-String des frühesten datierten Eintrags (nach echter Zeit
    # verglichen – die Strings tragen unterschiedliche Zeitzonen-Offsets, ein
    # lexikografischer Vergleich wäre falsch).
    def earliest_dated_start(clubs)
      dated = Array(clubs).select { |c| c['created_at'].present? }
      return nil if dated.empty?

      dated.min_by { |c| Time.zone.parse(c['created_at']) }['created_at']
    end
  end
end
