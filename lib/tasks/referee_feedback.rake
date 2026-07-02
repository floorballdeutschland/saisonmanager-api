# frozen_string_literal: true

# Fallback-Benachrichtigung für Schiri-Feedback: Die TMs werden primär direkt
# beim Abschluss des Spielberichts informiert (GamesController#set_game_status
# → RefereeFeedbackNotifier). Dieser Task fängt Spiele ab, die abgeschlossen
# sind, aber noch keine Benachrichtigung erhalten haben – etwa in Ligen, die
# erst nachträglich per referee_feedback_enabled freigeschaltet wurden.
# Idempotent über games.referee_feedback_notified_at.
#
# Per Cron/Scheduler aufrufen (z. B. stündlich/täglich):
#   bundle exec rails referee_feedback:notify_available
namespace :referee_feedback do
  desc 'TMs über verfügbare Schiri-Feedback-Formulare benachrichtigen (idempotent)'
  task notify_available: :environment do
    lookback = 3.days # begrenzt den Altbestand beim ersten Lauf (keine Mail-Flut)

    games = Game.joins(game_day: :league)
                .includes(:home_team, :guest_team, game_day: :league)
                .where(leagues: { referee_feedback_enabled: true })
                .where(referee_feedback_notified_at: nil)
                .where(game_status: %w[match_record_closed finalized])
                .where("TO_DATE(game_days.date, 'YYYY-MM-DD') BETWEEN ? AND ?",
                       lookback.ago.to_date, Date.current)

    mails = 0
    # deliver_now: in einem Cron-Rake gingen async-Jobs beim Prozessende verloren.
    games.find_each { |game| mails += RefereeFeedbackNotifier.new(game).notify(deliver_now: true) }

    puts "Schiri-Feedback-Benachrichtigung: #{mails} Mails versendet."
  end

  # Verknüpft bereits abgegebene Feedbacks nachträglich mit den tatsächlich
  # eingesetzten Schiedsrichtern aus dem Spielbericht. Nötig für Altbestände,
  # die noch über die (oft leere) Ansetzung verknüpft wurden und dadurch auf
  # keinem Schiri-Profil auftauchen. Idempotent; verarbeitet nur Feedbacks ohne
  # jede Schiri-Verknüpfung.
  #
  #   bundle exec rails referee_feedback:backfill_referees
  desc 'Bestehende Feedbacks ohne Schiri-Verknüpfung aus dem Spielbericht auflösen'
  task backfill_referees: :environment do
    updated = 0
    RefereeFeedback.where(referee1_id: nil, referee2_id: nil).includes(:game).find_each do |feedback|
      game = feedback.game
      next unless game

      referees = game.officiating_referees.presence || game.nominated_referees
      next if referees.empty?

      names = game.officiating_referee_names
      names = referees.map { |r| "#{r.vorname} #{r.nachname}".strip } if names.empty?

      feedback.update_columns(
        referee1_id: referees[0]&.id,
        referee2_id: referees[1]&.id,
        referee_names: names.join(' / ').presence
      )
      updated += 1
    end

    puts "Schiri-Feedback-Backfill: #{updated} Feedback(s) verknüpft."
  end
end
