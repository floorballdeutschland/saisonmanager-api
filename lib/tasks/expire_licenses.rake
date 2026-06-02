# lib/tasks/expire_licenses.rake
#
# Täglicher Job: Setzt alle Lizenzen mit abgelaufenem valid_until auf DELETED.
# Ergänzt den bestehenden Saisonwechsel-Task (invalidate_stale_licenses).
#
# Aufruf: rake licenses:expire ADMIN_USER_ID=1
# Für Cron (täglich): 0 2 * * * cd /app && bundle exec rake licenses:expire ADMIN_USER_ID=1

namespace :licenses do
  desc 'Setzt alle aktiven Lizenzen (APPROVED), deren valid_until überschritten ist, auf DELETED. ADMIN_USER_ID=… setzen.'
  task expire: :environment do
    dry_run = ENV['DRY_RUN'].present?
    admin_user_id = ENV['ADMIN_USER_ID'].to_i
    abort 'ADMIN_USER_ID nicht gesetzt' if admin_user_id.zero?

    admin = User.find_by(id: admin_user_id)
    abort "User #{admin_user_id} nicht gefunden" unless admin

    today = Date.today
    now = Time.now
    expired = 0
    updated_players = 0

    Player.where.not(licenses: nil).find_each do |player|
      changed = false

      (player.licenses || []).each do |license|
        valid_until_str = license['valid_until']
        next if valid_until_str.blank?

        valid_until = Date.parse(valid_until_str) rescue nil
        next if valid_until.nil? || valid_until >= today

        last = (license['history'] || []).max_by { |h| h['created_at'] }
        next unless last && last['license_status_id'].to_i == License::APPROVED

        license['history'] << {
          'license_status_id' => License::DELETED,
          'reason' => "Lizenz abgelaufen (valid_until: #{valid_until_str})",
          'created_by' => admin_user_id,
          'created_at' => now
        }
        changed = true
        expired += 1
      end

      if changed
        updated_players += 1
        player.save!(validate: false) unless dry_run
      end
    end

    msg = "#{expired} abgelaufene Lizenz(en) auf #{updated_players} Spieler:innen invalidiert"
    puts(dry_run ? "[DRY RUN] #{msg}." : "#{msg}.")
  end
end
