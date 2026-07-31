# frozen_string_literal: true

module LegacyImport
  # Ordnet vereinslosen Spielerprofilen einen OFFENEN Heimatverein zu, damit die
  # Vereine sie im eigenen Konto sehen und per Merge-Antrag mit dem lebenden
  # Profil derselben Person zusammenführen können.
  #
  # Scope-Kriterium ist die FEHLENDE Mitgliedschaft, nicht die Herkunft: in der
  # Praxis sind das die Profile aus dem Altdaten-Import 2010 bis 2014, weil
  # `Transformer.player_attrs` nur Name, Geburtsdatum und Geschlecht setzt und das
  # Alt-Bundle keine Mitgliedschaftstabelle enthält. Ein echtes Herkunftsmerkmal
  # gibt es nur an den Lizenzen (`LIC:`-Präfix); `HomeClubBackfillData#scope`
  # grenzt zusätzlich über `created_by IS NULL` ab.
  #
  # WICHTIG `valid_until` bleibt leer. `Club#players` filtert auf gültige
  # Mitgliedschaft, und diese Liste füttert über `vm_players_index` das
  # Duplikat-Dropdown des Merge-Antrags (`loadMergeClubPlayers` im Frontend, das
  # zusätzlich auf `deactivated_at` filtert). Ein geschlossener Eintrag wäre dort
  # nicht auswählbar. Die Antrags-Validierung selbst (`merge_must_be_executable`,
  # `player_belongs_to_club?`) prüft `valid_until` NICHT, die Anforderung kommt
  # also allein aus der Liste und dem Frontend.
  #
  # Gruppen, die `decide` in dieser Reihenfolge prüft:
  #   K  Geburtsdatum fehlt, Dublettenabgleich nicht möglich          übersprungen
  #   L  Lizenz-Team nicht auflösbar, Vereins-Set unvollständig       übersprungen
  #   A  genau ein aktiver Dubletten-Verein                           SCHREIBT
  #   B  aktive Dubletten in verschiedenen Vereinen                   übersprungen
  #   M  aktive Dublette ohne gültige Heimatmitgliedschaft            übersprungen
  #   H  aktive Dublette nur in Ablage-/deaktiviertem Verein          übersprungen
  #   D  genau ein deaktivierter Dubletten-Verein                     SCHREIBT
  #   C  deaktivierte Dubletten in verschiedenen Vereinen             übersprungen
  #   I  Kandidat selbst vereinslos, Lizenz-Verein eindeutig          SCHREIBT
  #   J  Kandidat selbst vereinslos, Lizenz-Verein nicht eindeutig    übersprungen
  #   G  keine belegende Lizenz und keine Dublette                    übersprungen
  #   E  keine verwertbare Dublette, Lizenz-Verein eindeutig          SCHREIBT
  #   F  keine verwertbare Dublette, Lizenz-Vereine mehrdeutig        übersprungen
  #   X  Entscheidung ohne brauchbaren Verein (Schutznetz)            übersprungen
  #
  # Ein aktiver Dubletten-Verein schlägt den Lizenz-Verein, ein deaktivierter
  # schlägt ihn ebenfalls: für einen Merge müssen beide Profile im selben
  # Vereinskonto liegen, und wer seit 2014 gewechselt hat, ist heute woanders.
  # Bei einer aktiven Dublette zählt nur ihr GÜLTIGER Heimateintrag; ein
  # geschlossener würde sie selbst nicht in `Club#players` bringen, das
  # Legacy-Profil hätte dort also keinen Merge-Partner (Gruppe M).
  #
  # Der Service bleibt DB-frei; Kandidaten, Lizenz-Vereine und die Liste der
  # Platzhalter- und deaktivierten Vereine kuratiert `HomeClubBackfillData`.
  module HomeClubBackfill
    # Marker im clubs-Eintrag. Neu in diesem JSONB: sonst schreibt niemand einen
    # `source`-Schlüssel (der reguläre Weg `Player#transfer` setzt `created_by`).
    # Der Marker ist die ALLEINIGE Grundlage für Idempotenz und Rücknahme, jeder
    # Eintrag ohne ihn gilt per Definition als fremd. Künftige Schreiber dürfen
    # ihn nicht wiederverwenden.
    SOURCE = 'legacy_import_backfill'

    # Vornamens-Abweichungen, die noch als dieselbe Person gelten.
    ACCEPTED_GRADES = %w[identisch vertauscht teilmenge abkuerzung].freeze

    # Gruppen, für die ein Eintrag geschrieben wird. Alle anderen sind Diagnose.
    WRITING_GROUPS = %w[A D E I].freeze

    # Kürzung erst ab dieser Länge des kürzeren Tokens, sonst matcht ein einzelner
    # Initial ("A." gegen "Anna") jeden Namen mit gleichem Anfangsbuchstaben, und
    # das ist keine Aussage über die Person.
    #
    # Bewusst NICHT strenger: "Jana" gilt weiterhin als Kürzung von "Jan", obwohl
    # das bei gleichem Nachnamen und Geburtsdatum Zwillinge sein können. Dieser
    # Task führt nichts zusammen, er macht das Profil nur im Vereinskonto sichtbar.
    # Der Merge ist danach eine eigene Handlung des Vereins mit Freigabe durch SBK
    # oder Admin, und ob zwei Profile im eigenen Verein dieselbe Person sind, weiß
    # der Verein besser als eine Namensheuristik. Eine strengere Schranke würde
    # dagegen echte Treffer wie "Timm"/"Timmy" verlieren.
    MIN_ABBREVIATION_LENGTH = 3

    module_function

    # Entscheidet für EIN Profil, welcher Verein gesetzt wird.
    #
    # player:     { first_name:, last_name:, gender: } des vereinslosen Profils
    # candidates: Dubletten-Kandidaten, je Hash mit
    #             id:, first_name:, gender:, active:, clubless:,
    #             current_home_club_id: (gültiger Heimateintrag, sonst nil)
    #             last_home_club_id:    (letzter bekannter, für deaktivierte)
    #             `clubless` heißt: der Kandidat ist selbst im Backfill-Scope und
    #             taugt daher nicht als Merge-Ziel.
    # license_club_ids:  Vereins-IDs aus den Lizenz-Teams
    # ignore_club_ids:   Platzhalter-, Ablage- und deaktivierte Vereine
    # birthdate_known:   false => Dublettenabgleich war nicht möglich
    # unresolved_license_teams: Anzahl Lizenzen, deren Team keinen Verein liefert
    #
    # Rückgabe: { group:, club_id:, reason:, candidate_id: }. club_id ist nil,
    # wenn nichts geschrieben werden soll.
    def decide(player:, candidates: [], license_club_ids: [], ignore_club_ids: [],
               birthdate_known: true, unresolved_license_teams: 0)
      ignore = ignore_club_ids.to_set
      licenses = Array(license_club_ids).compact.reject { |id| ignore.include?(id) }.uniq

      # Ein fehlendes Geburtsdatum heißt NICHT "keine Dublette", sondern "nicht
      # prüfbar". Ohne diese Trennung würde ein Profil über den Lizenz-Verein
      # geschrieben, obwohl der Abgleich nie stattgefunden hat.
      return skipped('K', 'Geburtsdatum fehlt, Dublettenabgleich nicht möglich') unless birthdate_known

      # Ein nicht auflösbares Lizenz-Team macht aus Mehrdeutigkeit falsche
      # Eindeutigkeit: aus zwei Vereinen würde stillschweigend einer.
      if unresolved_license_teams.positive?
        return skipped('L', "#{unresolved_license_teams} Lizenz-Team(s) ohne Verein, Vereins-Set unvollständig")
      end

      matches = accepted_candidates(player, candidates)
      usable = matches.reject { |c| c[:clubless] }

      active = usable.select { |c| c[:active] }
      active_clubs = distinct_usable_clubs(active, :current_home_club_id, ignore)

      if active_clubs.size == 1
        pick = active.find { |c| c[:current_home_club_id] == active_clubs.first }
        return decided('A', active_clubs.first, 'aktive Dublette', pick)
      end
      return skipped('B', "aktive Dubletten in #{active_clubs.size} verschiedenen Vereinen") if active_clubs.size > 1

      # Aktive Dublette vorhanden, aber ohne gültige Heimatmitgliedschaft: sie
      # steht selbst nicht über einen Heimateintrag in Club#players, ein dort
      # abgelegtes Legacy-Profil hätte keinen Merge-Partner.
      if active.any? { |c| c[:current_home_club_id].blank? && c[:last_home_club_id].present? }
        return skipped('M', 'aktive Dublette vorhanden, aber ohne gültige Heimatmitgliedschaft')
      end
      if active.any? { |c| c[:current_home_club_id].present? }
        return skipped('H', 'aktive Dublette nur in Ablage-/deaktiviertem Verein')
      end

      # Deaktivierte Dublette: der Verein ist eindeutig, der Merge braucht aber
      # einen Admin, weil Club#players über Player.active filtert.
      deactivated = usable.reject { |c| c[:active] }
      deactivated_clubs = distinct_usable_clubs(deactivated, :last_home_club_id, ignore)

      if deactivated_clubs.size == 1
        pick = deactivated.find { |c| c[:last_home_club_id] == deactivated_clubs.first }
        return decided('D', deactivated_clubs.first, 'deaktivierte Dublette', pick)
      end
      if deactivated_clubs.size > 1
        return skipped('C', "deaktivierte Dubletten in #{deactivated_clubs.size} verschiedenen Vereinen")
      end

      clubless_partners = matches.select { |c| c[:clubless] }
      if clubless_partners.any?
        partners = clubless_partners.map { |c| c[:id] }.join(',')
        return decided('I', licenses.first, "Lizenz-Verein (Partner ohne Verein: #{partners})") if licenses.size == 1

        return skipped('J', license_reason(licenses, "Partner ohne Verein: #{partners}"))
      end

      return skipped('G', 'keine belegende Lizenz und keine Dublette') if licenses.empty?
      return decided('E', licenses.first, 'Lizenz-Verein') if licenses.size == 1

      skipped('F', "keine verwertbare Dublette, #{licenses.size} Lizenz-Vereine")
    end

    # Der zu schreibende clubs-Eintrag.
    #
    # created_at trägt den frühesten belegten Zeitpunkt der Zugehörigkeit
    # (frühester Lizenz-Verlaufseintrag bei diesem Verein), damit im Profil
    # "von … bis heute" statt eines erfundenen Startdatums steht. Zwei
    # Nebenwirkungen hängen daran:
    #   - `MembershipCloser#open_legacy?` verlangt einen Eintrag OHNE created_at,
    #     kann diesen Eintrag also nie schließen.
    #   - `Player#_merge_clubs` sortiert nach created_at und `Player#home_club`
    #     nimmt den letzten gültigen Heimateintrag. Ein historisches Datum
    #     sortiert früh und lässt den echten Heimatverein des Masters vorn.
    # Fehlt ein Belegzeitpunkt (Dubletten-Verein ohne eigene Lizenz), wird der
    # Zeitpunkt des Backfills eingetragen; dann kann ein Merge den Heimatverein
    # des Masters auf diesen Verein umstellen.
    def build_entry(club_id:, created_at: nil)
      {
        'club_id' => club_id,
        'home_club' => true,
        'created_at' => created_at.presence || Time.current.iso8601,
        'source' => SOURCE
      }
    end

    # Idempotenz. Ein einziger FREMDER Eintrag lässt den Schreibvorgang komplett
    # ausfallen (Doppelsicherung zum Scope-SQL); eigene Alt-Einträge werden durch
    # den neuen ersetzt. Einen eigenen, aber inzwischen GESCHLOSSENEN Eintrag
    # fasst der Backfill nicht mehr an: das Schließen war eine menschliche
    # Entscheidung (VM in der UI, `Player#deactivate!`), die ein zweiter Lauf
    # nicht stillschweigend zurücknehmen darf.
    #
    # Gibt [neues_clubs_array, status] zurück, mutiert die Eingabe nicht.
    # status: :written, :unchanged, :foreign_entry, :closed_by_hand
    def apply(clubs, entry)
      existing = Array(clubs).map(&:dup)
      own, foreign = existing.partition { |c| c['source'] == SOURCE }

      return [existing, :foreign_entry] if foreign.any?
      return [existing, :closed_by_hand] if own.any? { |c| c['valid_until'].present? }
      return [existing, :unchanged] if own.size == 1 && own.first['club_id'] == entry['club_id']

      [[entry], :written]
    end

    # Rücknahme: nur die eigenen Einträge entfernen. Gibt [rest, entfernte]
    # zurück, damit der Aufrufer benennen kann, was verworfen wurde (ein Verein
    # kann den Eintrag zwischenzeitlich bearbeitet haben).
    #
    # Nach einem Merge sind drei Fälle möglich, alle über den Marker erreichbar:
    #   - Der Marker bleibt immer am deaktivierten Secondary stehen, weil
    #     `Player#deactivate!` nur `valid_until` stempelt.
    #   - Führt der Master denselben Verein OFFEN, verwirft `_merge_clubs` den
    #     Eintrag (Regelfall der Gruppe A).
    #   - Führt der Master ihn geschlossen oder gar nicht (Regelfall E und I),
    #     wandert der Eintrag auf den Master.
    def revert(clubs)
      existing = Array(clubs).map(&:dup)
      removed = existing.select { |c| c['source'] == SOURCE }

      [existing - removed, removed]
    end

    # Vornamens-Abweichung klassifizieren.
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

    # Nur 'ß' muss vor der NFKD-Zerlegung ersetzt werden: NFKD zerlegt es nicht,
    # und der `[^a-z0-9]`-Filter würde es ersatzlos schlucken ("Huß" → "hu"). Die
    # Umlaute erledigt NFKD zusammen mit dem `\p{Mn}`-Strip, das `tr` ist
    # Doppelsicherung für bereits zerlegte Eingaben.
    #
    # Bewusste Grenze: die Faltung ist einbuchstabig, "Grün" fällt also NICHT mit
    # "Gruen" zusammen. Eine zusätzliche ae/oe/ue-Faltung würde Namen wie "Manuel"
    # zu "Manul" verstümmeln und eigene Fehltreffer erzeugen.
    def normalize(str)
      str.to_s.downcase.gsub('ß', 'ss').tr('äöü', 'aou').unicode_normalize(:nfkd).gsub(/\p{Mn}/, '')
    end

    # Kandidaten mit passender Vornamens-Schreibweise. Zusätzlich fällt heraus,
    # wer ein bekanntes, ABWEICHENDES Geschlecht hat: das trennt Geschwister mit
    # gleichem Geburtsdatum, die sonst über die Kürzungsregel zusammenfallen
    # könnten. Ist eines der beiden Geschlechter unbekannt, greift der Schutz
    # nicht und es bleibt bei der Namensprüfung.
    def accepted_candidates(player, candidates)
      Array(candidates).select do |c|
        ACCEPTED_GRADES.include?(grade(player[:first_name], c[:first_name])) &&
          !contradicting_gender?(player[:gender], c[:gender])
      end
    end

    def contradicting_gender?(gender_a, gender_b)
      gender_a.present? && gender_b.present? && gender_a.to_s.casecmp(gender_b.to_s) != 0
    end

    # Verschiedene brauchbare Vereine der Kandidaten. Entschieden wird über die
    # Anzahl VEREINE, nicht über die Anzahl Kandidaten: drei Profile einer Person
    # in einem Verein sind genau die Population, die der Verein mergen soll.
    def distinct_usable_clubs(candidates, field, ignore)
      candidates.map { |c| c[field] }.select { |id| usable?(id, ignore) }.uniq
    end

    # Gleiche Token-Anzahl und jedes Token ist Präfix seines Partners, wobei das
    # kürzere lang genug sein muss (MIN_ABBREVIATION_LENGTH). Über die sortierten
    # Token verglichen, damit eine zusätzliche Vertauschung nicht durchfällt.
    def abbreviation?(tokens_a, tokens_b)
      return false unless tokens_a.size == tokens_b.size

      tokens_a.sort.zip(tokens_b.sort).all? do |x, y|
        next true if x == y

        (x.start_with?(y) || y.start_with?(x)) && [x.length, y.length].min >= MIN_ABBREVIATION_LENGTH
      end
    end

    def usable?(club_id, ignore)
      club_id.present? && !ignore.include?(club_id)
    end

    # "mehrdeutig" wäre falsch, wenn es gar keine Lizenz gibt.
    def license_reason(licenses, prefix)
      suffix = licenses.empty? ? 'keine belegende Lizenz' : "#{licenses.size} Lizenz-Vereine"
      "#{prefix}, #{suffix}"
    end

    def decided(group, club_id, reason, candidate = nil)
      # Schutznetz mit eigenem Buchstaben: eine leere club_id darf nicht als
      # schreibende Gruppe gezählt und dann nirgends berichtet werden.
      return skipped('X', "#{reason}, aber kein brauchbarer Verein") if club_id.blank?

      { group:, club_id:, reason:, candidate_id: candidate && candidate[:id] }
    end

    def skipped(group, reason)
      { group:, club_id: nil, reason:, candidate_id: nil }
    end
  end
end
