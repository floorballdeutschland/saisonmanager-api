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
  # frühesten datierten Folgeeintrags in einem ANDEREN, echten Verein.
  # Ausgeschlossen bei der Folgeverein-Bestimmung:
  #   - Einträge desselben Vereins (Rückkehr/Freigabe ist kein „Folgeverein"),
  #   - Platzhalter-/Ablage-Vereine (per `ignore_club_ids` vom Aufrufer, der die
  #     Club-Tabelle kennt – der Service bleibt DB-frei/testbar).
  # Bleibt danach kein datierter Folgeeintrag, bleibt die Mitgliedschaft offen.
  module MembershipCloser
    module_function

    # clubs: Array der Player#clubs-Hashes. ignore_club_ids: club_ids, die nicht als
    # Folgeverein zählen (Platzhalter/Ablage/deaktiviert). Gibt [neues_clubs_array,
    # changed?] zurück; das Eingabe-Array wird nicht mutiert.
    def close(clubs, ignore_club_ids: [])
      clubs = Array(clubs)
      ignore = ignore_club_ids.to_set
      changed = false

      new_clubs = clubs.map do |entry|
        next entry unless open_legacy?(entry)

        successor = successor_start(clubs, entry['club_id'], ignore)
        next entry if successor.nil?

        changed = true
        entry.merge('valid_until' => successor)
      end

      [new_clubs, changed]
    end

    # Offener Legacy-Eintrag: weder Beginn (created_at) noch Ende (valid_until).
    def open_legacy?(entry)
      entry['created_at'].blank? && entry['valid_until'].blank? && entry['club_id'].present?
    end

    # created_at-String des frühesten datierten Folgeeintrags in einem ANDEREN,
    # nicht ignorierten Verein. nil, wenn es keinen gibt. Vergleich nach echter
    # Zeit (die Strings tragen unterschiedliche Zeitzonen-Offsets, ein
    # lexikografischer Vergleich wäre falsch).
    def successor_start(clubs, open_club_id, ignore_club_ids = Set.new)
      ignore = ignore_club_ids.to_set
      dated = Array(clubs).select do |c|
        c['created_at'].present? && c['club_id'] != open_club_id && !ignore.include?(c['club_id'])
      end
      return nil if dated.empty?

      dated.min_by { |c| Time.zone.parse(c['created_at']) }['created_at']
    end
  end
end
