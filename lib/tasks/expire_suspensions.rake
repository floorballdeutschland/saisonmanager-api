# lib/tasks/expire_suspensions.rake

namespace :licenses do
  desc 'Hebt fällige Spielersperren auf (valid_until < heute), reaktiviert betroffene Lizenzen. Optional DRY_RUN=1.'
  task expire_suspensions: :environment do
    dry_run = ENV['DRY_RUN'].present?
    today = Date.current

    due = PlayerSuspension.due(today).includes(:player)
    lifted = 0

    due.find_each do |suspension|
      if dry_run
        lifted += 1
        next
      end

      suspension.player.lift_suspension!(suspension, user_id: suspension.created_by, reason: 'Sperre abgelaufen')
      lifted += 1
    end

    msg = "#{lifted} fällige Sperre(n) aufgehoben"
    puts(dry_run ? "[DRY RUN] #{msg}." : "#{msg}.")
  end
end
