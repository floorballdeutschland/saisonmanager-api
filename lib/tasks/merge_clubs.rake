# lib/tasks/merge_clubs.rake
#
# Legt zwei Vereine zusammen: alle Referenzen des aufzulösenden Vereins wandern
# auf den verbleibenden, danach wird der aufgelöste Verein gelöscht.
#
# Gedacht für zwei Fälle:
#   1. Dubletten – derselbe Verein liegt zweimal in der Datenbank (Altdaten-Import,
#      versehentliche Neuanlage bei der Saison-Anmeldung).
#   2. Echte Vereinsfusionen – zwei getrennte Vereine sind in der Wirklichkeit
#      einer geworden. Fachlich verschieden, technisch dieselbe Operation:
#      die Historie des aufgelösten Vereins bleibt am verbleibenden erhalten.
#
# Die Stammdaten des verbleibenden Vereins (Name, Kurzname, Registername,
# Landesverband, Logo, Kontakt-E-Mail) bleiben unangetastet. Sein Landesverband
# entscheidet weiter, wer den Verein verwaltet; der des aufgelösten Vereins
# verschwindet mit ihm.
#
# Dry-Run (Standard, rollt die Transaktion am Ende zurück):
#   bundle exec rails clubs:merge MERGES="286:12"
#
# Ausführen:
#   bundle exec rails clubs:merge MERGES="286:12" DRY_RUN=false [USER_ID=<id>]
#
# Mehrere Paare, komma-getrennt (jedes Paar in eigener Transaktion):
#   bundle exec rails clubs:merge MERGES="286:12,304:57"
#
# Format je Paar: <aufzulösende ID>:<verbleibende ID>
#
# Referenzübersicht (Stand Schema 2026-08): teams.club_id, teams.syndicate_clubs[],
# game_days.club_id, referees.club_id, referee_assignments.club_id,
# referee_club_exclusions.club_id, referee_club_exclusion_requests.club_id,
# referee_change_requests.new_club_id,
# referee_course_results.master_club_id_by_importer/_final, referee_feedbacks.club_id,
# player_change_requests.club_id, transfer_requests.requesting_club_id/former_club_id,
# transfers.former_club_id/new_club_id, users.club_id, users.permissions[].club_id (JSONB),
# players.clubs[].club_id (JSONB).

namespace :clubs do
  desc 'Zwei Vereine zusammenlegen (MERGES="<auflösen>:<behalten>,..."). DRY_RUN=false zum Ausführen.'
  task merge: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    user_id = ENV['USER_ID'].presence&.to_i
    pairs = ClubMergeHelper.parse_merges(ENV.fetch('MERGES', ''))

    puts "=== Vereins-Merge #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts

    if pairs.empty?
      puts 'Kein Paar angegeben. Beispiel: MERGES="286:12" (286 wird aufgelöst, 12 bleibt).'
      next
    end

    pairs.each do |source_id, target_id|
      ClubMergeHelper.run(source_id, target_id, dry_run: dry_run, user_id: user_id)
      puts
    end

    puts dry_run ? 'DRY RUN – nichts gespeichert. Mit DRY_RUN=false ausführen.' : 'Fertig.'
  end
end

# Eigenes Modul statt Methoden am Club: die Operation ist ein Wartungsvorgang,
# keine Fachlogik des Modells, und soll nicht über Controller erreichbar sein.
module ClubMergeHelper
  class << self
    # Modelle mit einer schlichten Vereins-Spalte: umhängen genügt, es gibt keine
    # Eindeutigkeitsregel, die dabei kippen könnte.
    #
    # Als Methode, nicht als Konstante: der Rumpf einer .rake-Datei läuft, bevor
    # die :environment-Abhängigkeit die Modelle autoladbar macht – Konstanten hier
    # oben liefen in einen NameError.
    def plain_columns
      [
        [Team,                'club_id'],
        [GameDay,             'club_id'],
        [Referee,             'club_id'],
        [RefereeAssignment,   'club_id'],
        [RefereeFeedback,     'club_id'],
        [PlayerChangeRequest, 'club_id'],
        [RefereeChangeRequest, 'new_club_id'],
        [TransferRequest,     'requesting_club_id'],
        [TransferRequest,     'former_club_id'],
        [Transfer,            'former_club_id'],
        [Transfer,            'new_club_id'],
        [User,                'club_id'],
        [RefereeCourseResult, 'master_club_id_by_importer'],
        [RefereeCourseResult, 'master_club_id_final']
      ]
    end

    # Modelle mit einem Unique-Index über (referee_id, club_id): würde das Umhängen
    # gegen einen bestehenden Eintrag des verbleibenden Vereins laufen, ist der
    # Eintrag des aufgelösten Vereins überzählig und wird gelöscht statt umgehängt.
    def referee_unique_models
      [RefereeClubExclusion, RefereeClubExclusionRequest]
    end

    # "286:12,304:57" → [[286, 12], [304, 57]]. Unbrauchbare Angaben brechen ab,
    # statt still ein Paar zu überspringen – ein Tippfehler in der ID darf nicht
    # dazu führen, dass nur die Hälfte der Merges läuft.
    def parse_merges(raw)
      raw.to_s.split(',').map(&:strip).reject(&:empty?).map do |pair|
        source, target = pair.split(':').map { |s| Integer(s.to_s.strip, exception: false) }
        raise ArgumentError, "Unlesbares Paar: #{pair.inspect} (erwartet <auflösen>:<behalten>)" if source.nil? || target.nil?

        [source, target]
      end
    end

    def run(source_id, target_id, dry_run:, user_id: nil)
      source = Club.find_by(id: source_id)
      target = Club.find_by(id: target_id)

      return puts "--- #{source_id} → #{target_id}: ÜBERSPRUNGEN (Verein ##{source_id} existiert nicht)" if source.nil?
      return puts "--- #{source_id} → #{target_id}: ÜBERSPRUNGEN (Verein ##{target_id} existiert nicht)" if target.nil?
      return puts "--- #{source_id} → #{target_id}: ÜBERSPRUNGEN (identische ID)" if source.id == target.id

      puts "--- Verein ##{source.id} „#{source.name}\" → ##{target.id} „#{target.name}\" ---"
      puts "  BEHALTEN:  ##{target.id} #{label(target)}"
      puts "  AUFLÖSEN:  ##{source.id} #{label(source)}"

      # Transaktion pro Paar, damit ein Fehler im zweiten Merge den ersten nicht
      # mitreißt. requires_new, weil der Task auch aus einer offenen Transaktion
      # heraus aufgerufen werden kann (Tests).
      ActiveRecord::Base.transaction(requires_new: true) do
        counts = apply(source, target, user_id: user_id)
        report(counts)
        raise ActiveRecord::Rollback if dry_run
      end
    end

    private

    def label(club)
      parts = ["LV #{club.state_association_id || '–'}"]
      parts << "zustaendiger Spielbetrieb #{club.main_game_operation_id || '–'}"
      parts << "#{Team.by_club_id(club.id).count} Mannschaft(en)"
      parts.join(' | ')
    end

    def apply(source, target, user_id:)
      counts = {}

      plain_columns.each do |model, column|
        moved = model.where(column => source.id).update_all(column => target.id)
        counts["#{model.table_name}.#{column}"] = moved if moved.positive?
      end

      referee_unique_models.each do |model|
        dropped, moved = repoint_referee_unique(model, source.id, target.id)
        counts["#{model.table_name}.club_id"] = moved if moved.positive?
        counts["#{model.table_name} (überzählig gelöscht)"] = dropped if dropped.positive?
      end

      {
        'teams.syndicate_clubs' => repoint_syndicates(source.id, target.id),
        'users.permissions' => repoint_user_permissions(source.id, target.id),
        'players.clubs' => repoint_player_clubs(source.id, target.id)
      }.each { |key, moved| counts[key] = moved if moved.positive? }

      MergeLog.record!(
        object_type: 'club',
        master_id: target.id, master_label: target.name,
        merged_id: source.id, merged_label: source.name,
        user_id: user_id
      )

      # dependent-Optionen am Club decken nur game_days ab; alles andere hängt
      # oben bereits am verbleibenden Verein, sonst schlägt der FK hier zu.
      source.destroy!

      counts
    end

    def report(counts)
      if counts.empty?
        puts '  Keine Referenzen zu verschieben.'
      else
        counts.each { |key, value| puts "  #{key}: #{value}" }
      end
      puts '  Verein aufgelöst und gelöscht.'
    end

    # Unique über (referee_id, club_id): existiert am verbleibenden Verein schon
    # ein Eintrag für denselben Schiri, wäre das Umhängen ein Duplikat.
    def repoint_referee_unique(model, source_id, target_id)
      existing_referee_ids = model.where(club_id: target_id).pluck(:referee_id)
      dropped = model.where(club_id: source_id, referee_id: existing_referee_ids).delete_all
      moved = model.where(club_id: source_id).update_all(club_id: target_id)
      [dropped, moved]
    end

    # syndicate_clubs ist ein Integer-Array, kein JSONB. uniq, damit ein Team, das
    # beide Vereine als Spielgemeinschafts-Partner führte, den verbleibenden
    # danach nicht zweimal enthält.
    def repoint_syndicates(source_id, target_id)
      teams = Team.where('? = ANY (syndicate_clubs)', source_id).to_a
      teams.each do |team|
        rewritten = team.syndicate_clubs.map { |id| id == source_id ? target_id : id }
        team.update_columns(syndicate_clubs: rewritten.uniq)
      end
      teams.size
    end

    # users.permissions[].club_id kann als String gespeichert sein (die API liest
    # per to_i). Ein typ-strenger Vergleich würde diese Referenzen übersehen und
    # der Verein wäre nach dem Löschen aus einer Rolle heraus nicht mehr auflösbar.
    def repoint_user_permissions(source_id, target_id)
      changed = 0
      User.where('permissions::text LIKE ?', "%\"club_id\"%").find_each do |user|
        permissions = Array(user.permissions)
        next unless permissions.any? { |perm| perm.is_a?(Hash) && perm['club_id'].to_i == source_id }

        rewritten = permissions.map do |perm|
          next perm unless perm.is_a?(Hash) && perm['club_id'].to_i == source_id

          perm.merge('club_id' => target_id)
        end

        user.update_columns(permissions: rewritten.uniq)
        changed += 1
      end
      changed
    end

    # players.clubs[].club_id – ebenfalls als String möglich. Hat ein Spieler
    # Mitgliedschaften in BEIDEN Vereinen, entstehen nach dem Umschreiben zwei
    # Einträge für denselben Verein: pro (club_id, team_id) bleibt der weitest
    # gültige übrig (offenes valid_until schlägt jedes Datum).
    def repoint_player_clubs(source_id, target_id)
      changed = 0
      Player.where('clubs::text LIKE ?', "%\"club_id\"%").find_each do |player|
        entries = Array(player.clubs)
        next unless entries.any? { |entry| entry.is_a?(Hash) && entry['club_id'].to_i == source_id }

        rewritten = entries.map do |entry|
          next entry unless entry.is_a?(Hash) && entry['club_id'].to_i == source_id

          entry.merge('club_id' => target_id)
        end

        player.update_columns(clubs: collapse_memberships(rewritten, target_id))
        changed += 1
      end
      changed
    end

    def collapse_memberships(entries, target_id)
      target_entries, others = entries.partition do |entry|
        entry.is_a?(Hash) && entry['club_id'].to_i == target_id
      end

      by_team = target_entries.group_by { |entry| entry['team_id'] }
      others + by_team.map { |_team_id, group| group.max_by { |entry| membership_rank(entry) } }
    end

    # Sortierschlüssel: offenes valid_until gewinnt, sonst das späteste Datum.
    def membership_rank(entry)
      return [1, ''] if entry['valid_until'].blank?

      [0, entry['valid_until'].to_s]
    end
  end
end
