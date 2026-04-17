# lib/tasks/fix_club_memberships.rake
#
# Korrigiert Legacy-Vereinseinträge ohne valid_until.
# Diese entstanden durch den Duplikat-Merge: das alte Profil hatte einen aktiven
# Vereinseintrag (valid_until = nil, created_at = nil), der beim Merge auf das neue
# Profil übertragen wurde – obwohl die Mitgliedschaft dort längst beendet war.
#
# Kriterium für betroffene Einträge:
#   - Eintrag ohne created_at und ohne valid_until (Legacy-Eintrag)
#   - Spieler hat zusätzlich mindestens einen datierten Eintrag bei einem ANDEREN Verein
#     (= klarer Hinweis, dass der Spieler den Verein gewechselt hat)
#   - Spieler ist NICHT noch aktiv in der aktuellen Saison bei dem betreffenden Verein
#     (= keine irrtümliche Schließung noch laufender Mitgliedschaften)
#
# Strategie für valid_until:
#   1. Spielhistorie: Letztes Spiel für ein Team des Vereins → Saisonende (31. August)
#   2. Fallback: Saisonende vor dem ältesten datierten Vereinseintrag
#
# Dry-Run (Standard):
#   bundle exec rails players:fix_club_valid_until
#
# Ausführen:
#   bundle exec rails players:fix_club_valid_until DRY_RUN=false

namespace :players do
  desc 'valid_until für Legacy-Vereinseinträge anhand Spielhistorie setzen. DRY_RUN=false zum Ausführen.'
  task fix_club_valid_until: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Club Valid-Until Fix #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts

    seasons      = Setting.current.seasons
    current_sid  = seasons.find { |_id, s| s['current'] }&.first&.to_i

    # Betroffene Spieler:
    #   - mind. ein Legacy-Eintrag (kein created_at, kein valid_until, club_id vorhanden)
    #   - mind. ein datierter Eintrag bei einem ANDEREN Verein als dem Legacy-Eintrag
    affected = Player.all.select do |p|
      clubs = Array(p.clubs)

      legacy = clubs.select { |c| c['created_at'].nil? && c['valid_until'].nil? && c['club_id'].present? }
      next false if legacy.empty?

      legacy_club_ids = legacy.map { |c| c['club_id'].to_s }.to_set

      clubs.any? { |c| c['created_at'].present? && !legacy_club_ids.include?(c['club_id'].to_s) }
    end

    puts "#{affected.size} Spieler mit zu korrigierenden Legacy-Vereinseinträgen gefunden.\n\n"

    total_fixed   = 0
    total_skipped = 0

    affected.each do |player|
      clubs = player.clubs.map(&:dup)

      # Ältester datierter Eintrag (für Fallback)
      dated = clubs.select { |c| c['created_at'].present? }.sort_by { |c| c['created_at'] }
      earliest_dated_date = dated.any? ? (Date.parse(dated.first['created_at'].to_s[0, 10]) rescue nil) : nil

      # Legacy-Einträge, deren Verein nicht unter den datierten Einträgen vorkommt
      dated_club_ids = dated.map { |c| c['club_id'].to_s }.to_set
      to_fix = clubs.select do |c|
        c['created_at'].nil? &&
          c['valid_until'].nil? &&
          c['club_id'].present? &&
          !dated_club_ids.include?(c['club_id'].to_s)
      end

      player_printed = false
      changed        = false

      to_fix.each do |entry|
        club_id = entry['club_id'].to_i

        # Spielhistorie: letzte Saison des Spielers bei diesem Verein
        last_sid, game_source = ClubMembershipHelper.last_game_season_id(player.id, club_id)

        # Sicherheitscheck: Spieler noch in aktueller Saison aktiv → nicht schließen
        if last_sid && current_sid && last_sid.to_i >= current_sid
          source = "Saison #{seasons[last_sid.to_s]&.dig('name')} ist noch aktiv"
          unless player_printed
            puts "--- ##{player.id} #{player.last_name}, #{player.first_name} ---"
            player_printed = true
          end
          puts "  club #{club_id}: SKIP – #{source}"
          total_skipped += 1
          next
        end

        # valid_until aus Saison-Enddatum berechnen
        valid_until, source = if last_sid
                                season_nm  = seasons[last_sid.to_s]&.dig('name')
                                end_year   = season_nm&.split('/')&.last&.to_i
                                if end_year
                                  [Date.new(end_year, 8, 31), "#{game_source} (Saison #{season_nm})"]
                                else
                                  [nil, nil]
                                end
                              end

        # Fallback: Saisonende vor erstem datiertem Eintrag
        if valid_until.nil? && earliest_dated_date
          valid_until = ClubMembershipHelper.previous_season_end(earliest_dated_date)
          source      = "Saisonende vor #{earliest_dated_date}"
        end

        unless player_printed
          puts "--- ##{player.id} #{player.last_name}, #{player.first_name} ---"
          player_printed = true
        end

        if valid_until
          puts "  club #{club_id}: → #{valid_until} [#{source}]#{dry_run ? ' [DRY RUN]' : ''}"
          unless dry_run
            entry['valid_until'] = valid_until.iso8601
            changed = true
          end
        else
          puts "  club #{club_id}: SKIP – kein Datum ermittelbar"
          total_skipped += 1
        end
      end

      if changed
        player.clubs = clubs
        player.save!(validate: false)
        total_fixed += 1
      end
    end

    puts "\nErgebnis: #{total_fixed} Spieler korrigiert, #{total_skipped} Einträge übersprungen"
    puts "[DRY RUN] Zum Ausführen: rails players:fix_club_valid_until DRY_RUN=false" if dry_run
  end
end

module ClubMembershipHelper
  module_function

  # Gibt die season_id der letzten Saison zurück, in der der Spieler für
  # ein Team des angegebenen Vereins gespielt hat.
  # Gibt [nil, nil] zurück, wenn keine Spielhistorie vorhanden.
  def last_game_season_id(player_id, club_id)
    team_ids = Team.by_club_id(club_id).pluck(:id)
    return [nil, nil] if team_ids.empty?

    home_ids = Game
      .where('players @> ?', { 'home' => [{ 'player_id' => player_id }] }.to_json)
      .where(home_team_id: team_ids)
      .joins(game_day: :league)
      .pluck('leagues.season_id')

    guest_ids = Game
      .where('players @> ?', { 'guest' => [{ 'player_id' => player_id }] }.to_json)
      .where(guest_team_id: team_ids)
      .joins(game_day: :league)
      .pluck('leagues.season_id')

    all_ids = (home_ids + guest_ids).compact
    return [nil, nil] if all_ids.empty?

    latest = all_ids.map(&:to_i).max
    [latest.to_s, 'Spielhistorie']
  end

  # Gibt das Ende der Saison zurück, die VOR dem übergebenen Datum endete.
  # September–Dezember → 31. August desselben Jahres.
  # Januar–August     → 31. August des Vorjahres.
  def previous_season_end(date)
    if date.month >= 9
      Date.new(date.year, 8, 31)
    else
      Date.new(date.year - 1, 8, 31)
    end
  end
end
