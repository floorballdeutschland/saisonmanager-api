# frozen_string_literal: true

module LegacyImport
  # Ordnet vereinslosen Profilen aus dem Altdaten-Import 2010–2014 einen OFFENEN
  # Heimatverein zu, damit die Vereine sie im eigenen Konto sehen und per
  # Merge-Antrag mit dem lebenden Profil zusammenführen können.
  #
  # Hintergrund: `Transformer.player_attrs` setzt beim Import nur Name, Geburts-
  # datum und Geschlecht; ein `Player#clubs`-Eintrag entsteht nie, und das
  # Alt-Bundle enthält auch keine Mitgliedschaftstabelle. Betroffene Profile sind
  # damit in KEINEM Vereinskonto sichtbar (`Club#players` selektiert über clubs).
  #
  # WICHTIG `valid_until` bleibt leer: `Club#players` filtert auf gültige
  # Mitgliedschaft, und diese Liste füttert über `vm_players_index` auch das
  # Duplikat-Dropdown des Merge-Antrags. Ein geschlossener Eintrag wäre dort nicht
  # auswählbar und der Backfill damit wirkungslos.
  #
  # Priorität der Zuordnung (siehe `decide`):
  #   1. Eindeutige aktive Dublette (gleicher Nachname + Geburtsdatum, Vorname nur
  #      in der Schreibweise abweichend) → deren AKTUELLER Heimatverein. Der
  #      schlägt den Lizenz-Verein, weil für einen Merge beide Profile im selben
  #      Konto liegen müssen: wer seit 2014 gewechselt hat, ist heute woanders.
  #   2. Ohne Dublette der Verein des Lizenz-Teams, aber nur wenn über alle
  #      Lizenzen hinweg eindeutig.
  # Alles andere wird bewusst übersprungen (mehrere Dubletten in verschiedenen
  # Vereinen, mehrdeutige Lizenz-Vereine, keine Anhaltspunkte).
  #
  # Bei einer AKTIVEN Dublette zählt nur ihr aktueller Heimatverein: ein bereits
  # geschlossener Eintrag würde sie selbst nicht in `Club#players` bringen, das
  # Legacy-Profil hätte dort also keinen Merge-Partner.
  #
  # Der Service bleibt DB-frei; Kandidaten, Lizenz-Vereine und die Liste der
  # Platzhalter-Vereine kuratiert `HomeClubBackfillData`.
  module HomeClubBackfill
    SOURCE = 'legacy_import_backfill'

    # Vornamens-Abweichungen, die noch als dieselbe Person gelten. 'abweichend'
    # (keine Token-Überlappung, z. B. Geschwister mit gleichem Geburtsdatum) gilt
    # NICHT als Treffer.
    ACCEPTED_GRADES = %w[identisch vertauscht teilmenge abkuerzung].freeze

    # Gruppen, für die ein Eintrag geschrieben wird. Der Rest ist Diagnose.
    WRITING_GROUPS = %w[A D E I].freeze

    module_function

    # Entscheidet für EIN Profil, welcher Verein gesetzt wird.
    #
    # player:     { first_name:, last_name: } des vereinslosen Profils
    # candidates: Dubletten-Kandidaten, je Hash mit
    #             id:, first_name:, active:, legacy:,
    #             current_home_club_id: (nur bei aktiven relevant),
    #             last_home_club_id:    (letzter bekannter, für deaktivierte)
    # license_club_ids: Vereins-IDs aus den Lizenz-Teams
    # ignore_club_ids:  Platzhalter-/Ablage-Vereine, nie als Ziel
    #
    # Rückgabe: { group:, club_id:, reason:, candidate_id: }. club_id ist nil,
    # wenn nichts geschrieben werden soll.
    def decide(player:, candidates: [], license_club_ids: [], ignore_club_ids: [])
      ignore = ignore_club_ids.to_set
      matches = accepted_candidates(player, candidates)
      licenses = Array(license_club_ids).compact.reject { |id| ignore.include?(id) }.uniq

      real = matches.reject { |c| c[:legacy] }
      active = real.select { |c| c[:active] }
      usable_active = active.select { |c| usable?(c[:current_home_club_id], ignore) }

      return decided('A', usable_active.first[:current_home_club_id], 'aktive Dublette', usable_active.first) if usable_active.size == 1
      return skipped('B', 'mehrere aktive Dubletten in verschiedenen Vereinen') if usable_active.size > 1

      # Aktive Dublette vorhanden, ihr Heimatverein ist aber ein Ablage-Verein:
      # sie taugt nicht als Ziel, der Lizenz-Verein darf einspringen.
      if active.any? { |c| c[:current_home_club_id].present? }
        return decided('E', licenses.first, 'Lizenz-Verein (Dublette in Ablage-Verein)') if licenses.size == 1

        return skipped('H', 'Dublette nur in Ablage-Verein, Lizenz-Verein mehrdeutig')
      end

      # Deaktivierte Dublette: Verein ist eindeutig, der Merge braucht aber einen
      # Admin, weil `Club#players` über `Player.active` filtert.
      deactivated = real.reject { |c| c[:active] }.select { |c| usable?(c[:last_home_club_id], ignore) }
      return decided('D', deactivated.first[:last_home_club_id], 'deaktivierte Dublette', deactivated.first) if deactivated.size == 1

      legacy_partners = matches.select { |c| c[:legacy] }
      if legacy_partners.any?
        partners = legacy_partners.map { |c| c[:id] }.join(',')
        return decided('I', licenses.first, "Lizenz-Verein (Legacy-Paar mit #{partners})") if licenses.size == 1

        return skipped('J', 'Legacy-Paar, Lizenz-Verein mehrdeutig')
      end

      return skipped('G', 'keine Lizenz und keine Dublette') if licenses.empty?
      return decided('E', licenses.first, 'Lizenz-Verein') if licenses.size == 1

      skipped('F', 'keine Dublette, Lizenz-Vereine mehrdeutig')
    end

    # Der zu schreibende clubs-Eintrag. created_at dokumentiert den frühesten
    # belegten Zeitpunkt der Zugehörigkeit (frühester Lizenz-Verlaufseintrag bei
    # diesem Verein), damit im Profil "von … bis heute" statt eines erfundenen
    # Startdatums steht. Fehlt ein Belegzeitpunkt (Dublette in einem anderen
    # Verein als die Lizenzen), wird der Zeitpunkt des Backfills eingetragen.
    def build_entry(club_id:, created_at: nil)
      {
        'club_id' => club_id,
        'home_club' => true,
        'created_at' => created_at.presence || Time.current.iso8601,
        'source' => SOURCE
      }
    end

    # Idempotenz: eigene Alt-Einträge ersetzen, fremde niemals anfassen.
    # Gibt [neues_clubs_array, changed?] zurück, mutiert die Eingabe nicht.
    def apply(clubs, entry)
      existing = Array(clubs).map(&:dup)
      own, foreign = existing.partition { |c| c['source'] == SOURCE }

      return [existing, false] if foreign.any?
      return [own, false] if own.size == 1 && own.first['club_id'] == entry['club_id'] && own.first['valid_until'].blank?

      [[entry], true]
    end

    # Rücknahme: nur die eigenen Einträge entfernen. Im Regelfall ist nach einem
    # Merge nichts mehr da: `Player#_merge_clubs` verwirft einen offenen Eintrag,
    # dessen Verein der Master schon aktiv führt — und genau dieser Verein wird
    # hier gesetzt. Nur wenn der Master denselben Verein bloß GESCHLOSSEN führt,
    # wandert der Eintrag mit, deshalb greift die Rücknahme auch bei Mastern.
    def revert(clubs)
      existing = Array(clubs).map(&:dup)
      kept = existing.reject { |c| c['source'] == SOURCE }

      [kept, kept.size != existing.size]
    end

    # Vornamens-Abweichung klassifizieren. Umlaute werden gefaltet und
    # Sonderzeichen entfernt, damit "Mark-Oliver"/"Mark Oli" und
    # "Per Flemming"/"Flemming Per" als dieselbe Person gelten.
    def grade(name_a, name_b)
      a = tokens(name_a)
      b = tokens(name_b)
      return 'leer' if a.empty? || b.empty?
      return 'identisch' if fold(name_a) == fold(name_b)
      return 'vertauscht' if a.sort == b.sort && a.size > 1
      return 'teilmenge' if (a & b).any? && ((a - b).empty? || (b - a).empty?)
      return 'abkuerzung' if abbreviation?(a, b)
      return 'teiltreffer' if (a & b).any?

      'abweichend'
    end

    def fold(str)
      normalize(str).gsub(/[^a-z0-9]/, '')
    end

    def tokens(str)
      normalize(str).split(/[^a-z0-9]+/).reject(&:empty?)
    end

    # ── intern ────────────────────────────────────────────────────────────────

    # Umlaute VOR der NFKD-Zerlegung ersetzen: 'ä' würde sonst zu 'a' + combining
    # diaeresis und 'ß' bliebe stehen. 'ß' wird zu 'ss', damit "Huß" und "Huss"
    # zusammenfallen; `tr` allein würde 'hus' liefern und beide trennen.
    # Bewusste Grenze: Umlaute werden einbuchstabig gefaltet ("Väinö" == "Vaino"),
    # die ae/oe/ue-Schreibweise fällt damit NICHT zusammen ("Grün" != "Gruen").
    # Beides gleichzeitig geht mit einer einzigen Faltung nicht, und die
    # einbuchstabige trifft die im Bestand häufigere Variante.
    def normalize(str)
      str.to_s.downcase.gsub('ß', 'ss').tr('äöü', 'aou').unicode_normalize(:nfkd).gsub(/\p{Mn}/, '')
    end

    def accepted_candidates(player, candidates)
      Array(candidates).select do |c|
        ACCEPTED_GRADES.include?(grade(player[:first_name], c[:first_name]))
      end
    end

    # Gleiche Token-Anzahl und jedes Token ist Präfix seines Partners:
    # "mark oli" vs "mark oliver". Über die sortierten Token verglichen, damit
    # eine zusätzliche Vertauschung nicht durchfällt.
    def abbreviation?(tokens_a, tokens_b)
      return false unless tokens_a.size == tokens_b.size

      tokens_a.sort.zip(tokens_b.sort).all? { |x, y| x.start_with?(y) || y.start_with?(x) }
    end

    def usable?(club_id, ignore)
      club_id.present? && !ignore.include?(club_id)
    end

    def decided(group, club_id, reason, candidate = nil)
      return skipped(group, "#{reason}, aber kein brauchbarer Verein") if club_id.blank?

      { group:, club_id:, reason:, candidate_id: candidate && candidate[:id] }
    end

    def skipped(group, reason)
      { group:, club_id: nil, reason:, candidate_id: nil }
    end
  end
end
