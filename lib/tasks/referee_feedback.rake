# frozen_string_literal: true

# Benachrichtigt Teammanager, sobald das Schiri-Feedback-Formular für ein
# gespieltes Spiel ihrer Mannschaft ausfüllbar ist (Fenster öffnet 24 h nach
# Anpfiff). Idempotent über games.referee_feedback_notified_at.
#
# Per Cron/Scheduler aufrufen (z. B. stündlich/täglich):
#   bundle exec rails referee_feedback:notify_available
namespace :referee_feedback do
  desc 'TMs über verfügbare Schiri-Feedback-Formulare benachrichtigen (idempotent)'
  task notify_available: :environment do
    tz = ActiveSupport::TimeZone['Europe/Berlin']
    now = Time.current
    fillable_after = 24.hours
    lookback = 3.days # begrenzt den Altbestand beim ersten Lauf (keine Mail-Flut)

    games = Game.joins(game_day: :league)
                .includes(:home_team, :guest_team, game_day: :league)
                .where(leagues: { referee_feedback_enabled: true })
                .where(referee_feedback_notified_at: nil)
                .where("TO_DATE(game_days.date, 'YYYY-MM-DD') BETWEEN ? AND ?",
                       lookback.ago.to_date, Date.current)

    notified = 0
    mails = 0

    games.find_each do |game|
      start = referee_feedback_game_start(game, tz)
      next if start.nil? || now < start + fillable_after # Fenster noch nicht offen

      [game.home_team, game.guest_team].compact.each do |team|
        referee_feedback_team_managers(team.id).each do |tm|
          # deliver_now: in einem Cron-Rake würden async-Jobs beim Prozessende verloren gehen.
          RefereeFeedbackMailer.form_available(tm, game, team).deliver_now
          mails += 1
        end
      end

      game.update_columns(referee_feedback_notified_at: now)
      notified += 1
    end

    puts "Schiri-Feedback-Benachrichtigung: #{notified} Spiele, #{mails} Mails versendet."
  end

  # Anpfiff (Spieltag-Datum + Startzeit) in Europe/Berlin; nil ohne Datum.
  def referee_feedback_game_start(game, tz)
    return nil if game.game_day&.date.blank?

    tz.parse("#{game.game_day.date} #{game.start_time}".strip)
  rescue ArgumentError, TypeError
    nil
  end

  # Teammanager der Mannschaft, die Info-Mails nicht abbestellt haben. `users.teams`
  # ist die TM-Team-Liste (VMs verwalten über den Verein, nicht über dieses Array),
  # zusätzlich gegen permission_hash[:tm] abgesichert.
  def referee_feedback_team_managers(team_id)
    User.where('? = ANY(teams)', team_id)
        .where(active: true, receive_info_mails: true)
        .where.not(email: [nil, ''])
        .select { |u| u.permission_hash[:tm].to_a.include?(team_id) }
  end
end
