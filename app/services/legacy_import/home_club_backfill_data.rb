# frozen_string_literal: true

module LegacyImport
  # DB-Beschaffung für HomeClubBackfill: lädt Dubletten-Kandidaten, Lizenz-Vereine
  # und die Liste der Platzhalter- und deaktivierten Vereine, damit der
  # Entscheidungs-Service DB-frei und testbar bleibt.
  #
  # Die Indizes werden EINMAL pro Instanz aufgebaut (Spieler-Stammdaten als
  # pluck, clubs nur für mögliche Kandidaten), sonst wäre der Lauf ein N+1 über
  # alle Profile. Eine Instanz entspricht damit einem Lauf: wer nach dem ersten
  # `decide_for` noch Datensätze anlegt, liest veraltete Indizes.
  class HomeClubBackfillData
    # Ein Verlaufsstatus, der eine Zugehörigkeit BELEGT. Nicht identisch mit
    # `License::ACTIVE_STATUSES`: `TRANSFER` heißt "ungültig wg. Transfer" und ist
    # hier trotzdem ein Beleg, denn ein Transfer beweist die Mitgliedschaft im
    # ABGEBENDEN Verein, und genau der ist gesucht. Eine abgelehnte, gelöschte
    # oder zurückgezogene Lizenz belegt dagegen nichts.
    MEMBERSHIP_PROVING_STATUSES = [License::APPROVED, License::REQUESTED, License::TRANSFER].freeze

    # Platzhalter- und Ablagevereine des Bestands. Gewachsene Liste aus dem
    # Alt-System: `z_`/`zz`-Präfixe für stillgelegte Vereine, "Ablage" für
    # Sammelbecken (Ausland, Doppelungen), "not in use" als Alt-Markierung. Ein
    # Fehltreffer würde einen echten Verein als Ziel ausschließen, das Profil also
    # nur übersehen, nicht falsch zuordnen.
    PLACEHOLDER_CLUB_PATTERN = '(^z_|^zz|ablage|not in use|doppelung)'

    def self.ignore_club_ids
      (Club.where('name ~* ?', PLACEHOLDER_CLUB_PATTERN).pluck(:id) +
       Club.where.not(deactivated_at: nil).pluck(:id)).uniq
    end

    # Vereinslose aktive Profile ohne fremden clubs-Eintrag.
    #
    # `created_by IS NULL` grenzt auf Import-Herkunft ab: die manuelle Anlage
    # setzt `created_by` (players_controller), der Altdaten-Import nicht. Ohne
    # diese Bedingung geriete auch ein abgebrochen angelegtes modernes Profil in
    # den Lauf und könnte über eine Namensgleichheit in ein fremdes Vereinskonto
    # geschrieben werden.
    #
    # Bereits bearbeitete Profile bleiben im Scope (sie tragen nur eigene
    # Einträge), damit ein zweiter Lauf idempotent ist. Sobald ein Verein einen
    # echten Eintrag DANEBEN legt, fällt das Profil heraus.
    def scope
      Player.where(deactivated_at: nil, merged_into_id: nil, created_by: nil).where(
        "NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(clubs,'[]'::jsonb)) e " \
        "WHERE coalesce(e->>'source','') <> ?)", HomeClubBackfill::SOURCE
      )
    end

    def ignore_club_ids
      @ignore_club_ids ||= self.class.ignore_club_ids
    end

    def decide_for(player)
      resolved = license_clubs(player)

      HomeClubBackfill.decide(
        player: { first_name: player.first_name, last_name: player.last_name, gender: player.gender },
        candidates: candidates_for(player),
        license_club_ids: resolved[:club_ids],
        ignore_club_ids: ignore_club_ids,
        birthdate_known: player.birthdate.present?,
        unresolved_license_teams: resolved[:unresolved]
      )
    end

    # Frühester Lizenz-Verlaufszeitpunkt des Spielers BEI DIESEM Verein, als
    # Belegzeit für created_at. nil, wenn es dort keine Lizenz gibt.
    #
    # Der String-Vergleich ist hier zulässig, weil nur `LIC:`-Lizenzen betrachtet
    # werden: `Transformer.license_attrs` schreibt deren Zeitstempel einheitlich
    # offsetfrei als YYYY-MM-DDTHH:MM:SS. Für `Player#clubs` gilt das NICHT, dort
    # warnt `MembershipCloser` zu Recht vor gemischten Zeitzonen-Offsets. Wer den
    # `LIC:`-Filter aufweicht, muss hier auf echte Zeit umstellen.
    def earliest_license_start(player, club_id)
      proving_licenses(player)
        .select { |l| team_club_ids[l['team_id']] == club_id }
        .flat_map { |l| Array(l['history']).filter_map { |h| h['created_at'].presence if h.is_a?(Hash) } }
        .min
    end

    # Profile im Scope, die kein einziges Merkmal des Altdaten-Imports tragen
    # (keine `LIC:`-Lizenz). Für den Bericht, damit ein Lauf nicht unbemerkt
    # moderne Profile mitnimmt.
    def profiles_without_legacy_marker(players)
      players.reject { |p| Array(p.licenses).any? { |l| l['id'].to_s.start_with?('LIC:') } }
    end

    # Profile, die `validates :nation_id, presence: true` nicht bestehen. Der
    # Import setzt nation_id nie, deshalb schreibt der Task mit
    # `save!(validate: false)`. Folge für den Betrieb: ein VM, der so ein Profil
    # in der UI öffnet und speichert, bekommt eine Validierungsmeldung.
    def profiles_failing_validation(players)
      players.reject(&:valid?)
    end

    private

    # Kandidaten: gleicher gefalteter Nachname UND gleiches Geburtsdatum.
    #
    # Die `merged_into_id`-Kette wird bis zum Master verfolgt, damit ein bereits
    # zusammengeführtes Duplikat auf das heute lebende Profil zeigt. Bewertet wird
    # der Vorname der GETROFFENEN Zeile (die Nachname und Geburtsdatum teilt),
    # als Ziel dient der Verein des MASTERS: dessen eigener Nachname und
    # Geburtsdatum werden absichtlich nicht erneut geprüft, denn er ist das
    # überlebende Profil der getroffenen Zeile. Zeigt die Kette auf das Profil
    # selbst zurück (ein zweites vereinsloses Profil wurde HINEIN gemergt), ist es
    # kein Kandidat.
    def candidates_for(player)
      return [] if player.birthdate.blank?

      key = [HomeClubBackfill.fold(player.last_name), player.birthdate.to_s]
      (index[key] || []).reject { |row| row[:id] == player.id }
                        .map { |row| [row, master_of(row)] }
                        .reject { |_row, master| master[:id] == player.id }
                        .uniq { |_row, master| master[:id] }
                        .map { |row, master| candidate_hash(row, master) }
    end

    def candidate_hash(matched, master)
      homes = home_entries(master[:id])

      {
        id: master[:id],
        first_name: matched[:first_name],
        gender: matched[:gender],
        active: master[:deactivated_at].nil?,
        clubless: clubless_ids.include?(master[:id]),
        current_home_club_id: homes[:current]&.dig('club_id'),
        last_home_club_id: homes[:last]&.dig('club_id')
      }
    end

    # Heimateinträge eines Kandidaten, getrennt in "heute gültig" und "letzter
    # bekannter". Eigene Backfill-Einträge zählen NICHT mit: sonst würde eine
    # frühere Vermutung dieses Tasks beim nächsten Lauf als Beleg gelesen und als
    # hochvertrauenswürdige Gruppe A berichtet.
    #
    # Nur Heimateinträge zählen. Eine Freigabe (`home_club: false`) macht den
    # Kandidaten zwar in `Club#players` sichtbar, ist aber kein Heimatverein und
    # damit kein Merge-Ziel.
    def home_entries(player_id)
      entries = Array(clubs_by_id[player_id])
                .reject { |c| c['source'] == HomeClubBackfill::SOURCE }
                .select { |c| c['home_club'] }

      { current: entries.reject { |c| expired?(c['valid_until']) }.last, last: entries.last }
    end

    # `Player#clubs` ist schemalos und wird von mehreren Codepfaden geschrieben,
    # teils mit Time-Objekten, teils mit Strings. Ein unlesbarer Wert darf nicht
    # den ganzen Lauf abbrechen; er gilt als abgelaufen, der Eintrag zählt dann
    # nur noch als "letzter bekannter".
    def expired?(valid_until)
      return false if valid_until.blank?

      valid_until.to_date < Date.current
    rescue ArgumentError, TypeError
      # Date::Error erbt von ArgumentError und ist damit mit abgedeckt.
      true
    end

    def master_of(row, seen = [])
      return row if row[:merged_into_id].blank? || seen.include?(row[:id])

      nxt = rows_by_id[row[:merged_into_id]]
      nxt ? master_of(nxt, seen + [row[:id]]) : row
    end

    # Vereine der Lizenz-Teams plus die Zahl der Lizenzen, deren Team keinen
    # Verein liefert (gelöschtes Team oder team.club_id nil). Die werden gezählt
    # statt verworfen: sonst würde aus zwei Vereinen stillschweigend einer und aus
    # Mehrdeutigkeit falsche Eindeutigkeit.
    def license_clubs(player)
      mapped = proving_licenses(player).map { |l| team_club_ids[l['team_id']] }

      { club_ids: mapped.compact.uniq, unresolved: mapped.count(&:nil?) }
    end

    # Nur Legacy-Lizenzen (`LIC:`-Präfix, vom Import geschrieben) und nur solche,
    # deren LETZTER Verlaufsstatus eine Zugehörigkeit belegt. Eine Lizenz ohne
    # Verlauf belegt nichts.
    def proving_licenses(player)
      Array(player.licenses).select { |l| l['id'].to_s.start_with?('LIC:') }.select do |l|
        history = Array(l['history']).select { |h| h.is_a?(Hash) }
        last = history.max_by { |h| h['created_at'].to_s }
        last && MEMBERSHIP_PROVING_STATUSES.include?(last['license_status_id'].to_i)
      end
    end

    # ── Vorgeladene Indizes ───────────────────────────────────────────────────

    def rows
      @rows ||= Player.pluck(:id, :first_name, :last_name, :birthdate, :gender, :deactivated_at, :merged_into_id)
                      .map do |id, first_name, last_name, birthdate, gender, deactivated_at, merged_into_id|
        { id:, first_name:, last_name:, birthdate:, gender:, deactivated_at:, merged_into_id: }
      end
    end

    def rows_by_id
      @rows_by_id ||= rows.index_by { |r| r[:id] }
    end

    def index
      @index ||= rows.reject { |r| r[:birthdate].blank? }
                     .group_by { |r| [HomeClubBackfill.fold(r[:last_name]), r[:birthdate].to_s] }
    end

    def clubless_ids
      @clubless_ids ||= scope.pluck(:id).to_set
    end

    # clubs nur für mögliche Kandidaten laden: Profile, deren Schlüssel aus
    # Nachname und Geburtsdatum mehrfach vorkommt, plus die Master am Ende ihrer
    # Merge-Ketten (die müssen den Schlüssel nicht teilen).
    def clubs_by_id
      @clubs_by_id ||= begin
        members = index.values.select { |group| group.size > 1 }.flatten
        ids = members.map { |r| r[:id] } + members.map { |r| master_of(r)[:id] }
        Player.where(id: ids.uniq).pluck(:id, :clubs).to_h
      end
    end

    def team_club_ids
      @team_club_ids ||= Team.pluck(:id, :club_id).to_h
    end
  end
end
