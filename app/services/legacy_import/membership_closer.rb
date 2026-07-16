# frozen_string_literal: true

module LegacyImport
  # Schließt offene Legacy-Vereinsmitgliedschaften eines Spielers.
  #
  # Legacy-Einträge aus dem Import 2010–2014 haben weder `created_at` noch
  # `valid_until` (= "bis heute" offen). Dieselbe Form haben aber auch normale,
  # WEITERHIN GÜLTIGE Heimatvereins-Mitgliedschaften aus der Zeit vor ~2015 —
  # die Alt-App schrieb damals kein `created_at`. Beide sind an den Feldern
  # allein nicht unterscheidbar.
  #
  # Regeln:
  # - Ein offener HEIMAT-Eintrag (home_club: true) endet nur mit einem echten
  #   Vereinswechsel, also dem `created_at` des frühesten datierten Folgeeintrags
  #   mit home_club: true. Eine bloße Freigabe (home_club: false) ist KEIN
  #   Vereinswechsel und schließt die Heimatmitgliedschaft nicht — sonst werden
  #   treue Stammvereins-Spieler fälschlich "ausgetreten" (Vorfall 2026-07-13:
  #   351 aktive Spieler verloren so ihre Heimatmitgliedschaft).
  # - Ein offener NICHT-Heimat-Eintrag (Legacy-Freigabe) endet mit dem
  #   `created_at` des frühesten datierten Folgeeintrags beliebiger Art.
  # - Ohne passenden Folgeeintrag bleibt die Mitgliedschaft offen.
  module MembershipCloser
    module_function

    # clubs: Array der Player#clubs-Hashes. Gibt [neues_clubs_array, changed?]
    # zurück; das Eingabe-Array wird nicht mutiert.
    def close(clubs)
      clubs = Array(clubs)

      changed = false
      new_clubs = clubs.map do |entry|
        successor = open_legacy?(entry) ? successor_start(entry, clubs) : nil
        if successor
          changed = true
          entry.merge('valid_until' => successor)
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

    # created_at-String des frühesten datierten Folgeeintrags, der den übergebenen
    # Eintrag beenden darf (Heimat nur durch Heimat-Folgeeintrag). Vergleich nach
    # echter Zeit — die Strings tragen unterschiedliche Zeitzonen-Offsets, ein
    # lexikografischer Vergleich wäre falsch. nil, wenn kein passender existiert.
    def successor_start(entry, clubs)
      dated = Array(clubs).select { |c| c['created_at'].present? }
      dated = dated.select { |c| c['home_club'] == true } if entry['home_club'] == true
      return nil if dated.empty?

      dated.min_by { |c| Time.zone.parse(c['created_at']) }['created_at']
    end

    # Rückwärtskompatibler Helper (nur noch für Auswertungen/Ausgaben):
    # frühester datierter Eintrag beliebiger Art.
    def earliest_dated_start(clubs)
      dated = Array(clubs).select { |c| c['created_at'].present? }
      return nil if dated.empty?

      dated.min_by { |c| Time.zone.parse(c['created_at']) }['created_at']
    end
  end
end
