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
end
