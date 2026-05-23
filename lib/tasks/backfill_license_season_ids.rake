# lib/tasks/backfill_license_season_ids.rake

namespace :licenses do
  desc 'Backfillt season_id (und league_class_id) auf Player-Lizenzen, die diese Felder nicht gesetzt haben (DRY_RUN=1 zum Testen)'
  task backfill_season_ids: :environment do
    dry_run = ENV['DRY_RUN'].present?

    # Team-Lookup vorab, um pro Player nicht erneut N Queries abzusetzen.
    team_info = Team.joins(:league).pluck('teams.id, leagues.season_id, leagues.league_class_id').to_h do |id, sid, cls|
      [id, { season_id: sid, league_class_id: cls }]
    end

    total_players = 0
    total_licenses = 0
    skipped_team_missing = 0

    Player.where.not(licenses: nil).find_each do |player|
      changed = false
      (player.licenses || []).each do |license|
        next if license['season_id'].present?

        info = team_info[license['team_id'].to_i]
        unless info
          skipped_team_missing += 1
          next
        end

        license['season_id'] = info[:season_id]
        license['league_class_id'] ||= info[:league_class_id]
        changed = true
        total_licenses += 1
      end

      if changed
        total_players += 1
        player.save!(validate: false) unless dry_run
      end
    end

    summary = "#{total_licenses} Lizenz(en) auf #{total_players} Spieler:innen aktualisiert"
    summary += " (#{skipped_team_missing} Lizenz(en) übersprungen — Team nicht mehr vorhanden)" if skipped_team_missing.positive?
    puts(dry_run ? "[DRY RUN] #{summary}." : "#{summary}.")
  end
end
