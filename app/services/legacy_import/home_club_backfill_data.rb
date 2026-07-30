# frozen_string_literal: true

module LegacyImport
  # DB-Beschaffung für HomeClubBackfill: lädt Dubletten-Kandidaten, Lizenz-Vereine
  # und die Liste der Platzhalter-Vereine, damit der Entscheidungs-Service DB-frei
  # und testbar bleibt.
  #
  # Die Indizes werden EINMAL pro Lauf aufgebaut (Player-Stammdaten als pluck,
  # clubs nur für Profile, deren Nachname/Geburtsdatum mehrfach vorkommt), sonst
  # wäre der Lauf ein N+1 über 31.000 Profile.
  class HomeClubBackfillData
    ACTIVE_LICENSE_STATUSES = [License::APPROVED, License::REQUESTED, License::TRANSFER].freeze
    PLACEHOLDER_CLUB_PATTERN = '(^z_|^zz|ablage|not in use|doppelung)'

    # Vereinslose aktive Profile. Bereits vom Backfill bearbeitete Profile bleiben
    # im Scope (nur eigene Einträge), damit ein zweiter Lauf idempotent ist.
    def scope
      Player.where(deactivated_at: nil, merged_into_id: nil).where(
        "clubs IS NULL OR jsonb_array_length(clubs) = 0 OR NOT EXISTS (" \
        "SELECT 1 FROM jsonb_array_elements(clubs) e " \
        "WHERE coalesce(e->>'source','') <> ?)", HomeClubBackfill::SOURCE
      )
    end

    def ignore_club_ids
      @ignore_club_ids ||= (
        Club.where('name ~* ?', PLACEHOLDER_CLUB_PATTERN).pluck(:id) +
        Club.where.not(deactivated_at: nil).pluck(:id)
      ).uniq
    end

    def decide_for(player)
      HomeClubBackfill.decide(
        player: { first_name: player.first_name, last_name: player.last_name },
        candidates: candidates_for(player),
        license_club_ids: license_club_ids(player),
        ignore_club_ids: ignore_club_ids
      )
    end

    # Frühester Lizenz-Verlaufseintrag des Spielers BEI DIESEM Verein, als Belegzeit
    # für created_at. nil, wenn es dort keine Lizenz gibt (Dubletten-Fall mit
    # abweichendem Verein).
    def earliest_license_start(player, club_id)
      active_licenses(player).select { |l| team_club_ids[l['team_id']] == club_id }
                             .flat_map { |l| Array(l['history']).map { |h| h['created_at'].to_s } }
                             .reject(&:empty?).min
    end

    private

    # Kandidaten: gleicher gefalteter Nachname UND gleiches Geburtsdatum. Die
    # merged_into_id-Kette wird bis zum Master verfolgt, damit ein bereits
    # zusammengeführtes Duplikat auf den heute gültigen Verein zeigt. Zeigt die
    # Kette auf das Profil selbst zurück (ein zweites Legacy-Profil wurde HINEIN
    # gemergt), ist es kein Kandidat.
    def candidates_for(player)
      return [] if player.birthdate.blank?

      key = [HomeClubBackfill.fold(player.last_name), player.birthdate.to_s]
      (index[key] || []).reject { |row| row[:id] == player.id }
                        .map { |row| master_of(row) }
                        .uniq { |row| row[:id] }
                        .reject { |row| row[:id] == player.id }
                        .map { |row| candidate_hash(row) }
    end

    def candidate_hash(row)
      homes = Array(clubs_by_id[row[:id]]).select { |c| c['home_club'] }
      current = homes.reject { |c| c['valid_until'].present? && c['valid_until'].to_date < Date.current }

      {
        id: row[:id],
        first_name: row[:first_name],
        active: row[:deactivated_at].nil?,
        legacy: legacy_ids.include?(row[:id]),
        current_home_club_id: current.last&.dig('club_id'),
        last_home_club_id: homes.last&.dig('club_id')
      }
    end

    def master_of(row, seen = [])
      return row if row[:merged_into_id].blank? || seen.include?(row[:id])

      nxt = rows_by_id[row[:merged_into_id]]
      nxt ? master_of(nxt, seen + [row[:id]]) : row
    end

    def license_club_ids(player)
      active_licenses(player).map { |l| team_club_ids[l['team_id']] }.compact.uniq
    end

    # Nur Legacy-Lizenzen (LIC:-IDs) und nur solche, deren letzter Verlaufsstatus
    # eine Zugehörigkeit belegt. Eine abgelehnte Lizenz ist kein Mitgliedsnachweis.
    def active_licenses(player)
      Array(player.licenses).select { |l| l['id'].to_s.start_with?('LIC:') }.select do |l|
        last = Array(l['history']).max_by { |h| h['created_at'].to_s }
        ACTIVE_LICENSE_STATUSES.include?(last&.dig('license_status_id').to_i)
      end
    end

    # ── Vorgeladene Indizes ───────────────────────────────────────────────────

    def rows
      @rows ||= Player.pluck(:id, :first_name, :last_name, :birthdate, :deactivated_at, :merged_into_id)
                      .map do |id, first_name, last_name, birthdate, deactivated_at, merged_into_id|
        { id:, first_name:, last_name:, birthdate:, deactivated_at:, merged_into_id: }
      end
    end

    def rows_by_id
      @rows_by_id ||= rows.index_by { |r| r[:id] }
    end

    def index
      @index ||= rows.reject { |r| r[:birthdate].blank? }
                     .group_by { |r| [HomeClubBackfill.fold(r[:last_name]), r[:birthdate].to_s] }
    end

    def legacy_ids
      @legacy_ids ||= scope.pluck(:id).to_set
    end

    # clubs nur für mögliche Kandidaten laden: Profile, deren (Nachname,
    # Geburtsdatum) mehrfach vorkommt, plus die Master am Ende ihrer Merge-Ketten
    # (die Kette kann mehrere Stufen haben, daher über master_of aufgelöst).
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
