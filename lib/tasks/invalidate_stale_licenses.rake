# lib/tasks/invalidate_stale_licenses.rake

namespace :seasons do
  desc 'Invalidiert (License::DELETED) alle aktiven Lizenzen (APPROVED/REQUESTED), deren Team zu einer Liga gehört, die nicht zur aktuellen Saison zählt. ADMIN_USER_ID=… und optional DRY_RUN=1 setzen'
  task invalidate_stale_licenses: :environment do
    dry_run = ENV['DRY_RUN'].present?
    admin_user_id = ENV['ADMIN_USER_ID'].to_i
    abort 'ADMIN_USER_ID nicht gesetzt' if admin_user_id.zero?

    admin = User.find_by(id: admin_user_id)
    abort "User #{admin_user_id} nicht gefunden" unless admin

    current_season_id = Setting.current_season_id

    # Team-Lookup vorab: alle bekannten Teams mit ihrer Saison.
    team_season = Team.joins(:league).pluck(:id, 'leagues.season_id').to_h
    active_statuses = [License::APPROVED, License::REQUESTED]

    invalidated = 0
    updated_players = 0
    skipped_team_missing = 0
    skipped_other_season = 0
    now = Time.now

    Player.where.not(licenses: nil).find_each do |player|
      changed = false
      (player.licenses || []).each do |license|
        last = (license['history'] || []).max_by { |h| h['created_at'] }
        next unless last && active_statuses.include?(last['license_status_id'].to_i)

        tid = license['team_id'].to_i
        sid = team_season[tid]

        if sid.nil?
          # Team wurde archiviert/gelöscht — Lizenz hängt im Vakuum.
          skipped_team_missing += 1
          next
        end

        next if sid.to_s == current_season_id.to_s

        # Lizenz gehört zu einem Team in einer anderen (= alten/zukünftigen) Saison
        skipped_other_season += 1 unless dry_run
        license['history'] << {
          'license_status_id' => License::DELETED,
          'reason' => 'Saisonwechsel — Lizenz aus Vorsaison',
          'created_by' => admin_user_id,
          'created_at' => now
        }
        changed = true
        invalidated += 1
      end

      if changed
        updated_players += 1
        player.save!(validate: false) unless dry_run
      end
    end

    msg = "#{invalidated} Lizenz(en) auf #{updated_players} Spieler:innen invalidiert"
    msg += " (#{skipped_team_missing} mit gelöschtem Team übersprungen)" if skipped_team_missing.positive?
    puts(dry_run ? "[DRY RUN] #{msg}." : "#{msg}.")
  end
end
