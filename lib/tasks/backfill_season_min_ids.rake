# lib/tasks/backfill_season_min_ids.rake

namespace :seasons do
  desc 'Backfillt min_team_id/min_league_id für Saisons, die diese Werte nicht gesetzt haben (DRY_RUN=1 zum Testen)'
  task backfill_min_ids: :environment do
    dry_run = ENV['DRY_RUN'].present?

    setting = Setting.first
    seasons = setting.seasons.dup
    changes = []

    seasons.each do |season_id, data|
      next if data['min_league_id'].present? && data['min_team_id'].present?

      league_ids = League.where(season_id: season_id).pluck(:id)
      team_ids   = Team.where(league_id: league_ids).pluck(:id)

      min_league = league_ids.min
      min_team   = team_ids.min

      # Saisons ohne eigene Ligen (z. B. frisch angelegt) bekommen max(id)+1 — dieselbe Logik
      # wie beim Anlegen einer neuen Saison.
      min_league ||= (League.maximum(:id) || 0) + 1
      min_team   ||= (Team.maximum(:id) || 0) + 1

      changes << {
        season_id: season_id,
        name: data['name'],
        old_min_league_id: data['min_league_id'],
        old_min_team_id: data['min_team_id'],
        new_min_league_id: min_league,
        new_min_team_id: min_team
      }

      unless dry_run
        seasons[season_id] = data.merge('min_league_id' => min_league, 'min_team_id' => min_team)
      end
    end

    if changes.empty?
      puts 'Alle Saisons haben bereits min_team_id/min_league_id gesetzt — nichts zu tun.'
      next
    end

    puts(dry_run ? '[DRY RUN] Folgende Saisons würden aktualisiert:' : 'Folgende Saisons werden aktualisiert:')
    changes.each do |c|
      puts "  Saison #{c[:season_id]} (#{c[:name]}): " \
           "min_league_id #{c[:old_min_league_id].inspect} → #{c[:new_min_league_id]}, " \
           "min_team_id #{c[:old_min_team_id].inspect} → #{c[:new_min_team_id]}"
    end

    unless dry_run
      setting.seasons = seasons
      setting.save!
      puts "#{changes.size} Saison(s) aktualisiert."
    end
  end
end
