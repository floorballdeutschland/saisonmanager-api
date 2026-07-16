# frozen_string_literal: true

# Benachrichtigt die Teammanager beider Mannschaften eines Spiels, dass das
# Schiri-Feedback-Formular ausfüllbar ist. Das Fenster öffnet, sobald der
# Spielbericht abgeschlossen ist (game_status match_record_closed/finalized).
#
# Idempotent über games.referee_feedback_notified_at. Ausgelöst direkt beim
# Bericht-Abschluss (GamesController#set_game_status); der Rake-Task
# referee_feedback:notify_available nutzt denselben Service als Fallback (z. B.
# für nachträglich per referee_feedback_enabled freigeschaltete Ligen).
class RefereeFeedbackNotifier
  def initialize(game)
    @game = game
  end

  # Verschickt die Info-Mails, falls fällig, und markiert das Spiel als
  # benachrichtigt. Gibt die Anzahl versendeter Mails zurück (0, wenn nicht
  # fällig oder keine passenden Teammanager). deliver_now nur für den Cron-Rake-
  # Kontext, in dem async-Jobs beim Prozessende verloren gingen.
  def notify(deliver_now: false)
    return 0 unless due?

    mails = 0
    [@game.home_team, @game.guest_team].compact.each do |team|
      self.class.team_managers(team.id).each do |tm|
        mail = RefereeFeedbackMailer.form_available(tm, @game, team)
        deliver_now ? mail.deliver_now : mail.deliver_later
        mails += 1
      end
    end

    @game.update_columns(referee_feedback_notified_at: Time.current)
    mails
  end

  # Teammanager der Mannschaft, die Info-Mails nicht abbestellt haben. `users.teams`
  # ist die TM-Team-Liste (VMs verwalten über den Verein, nicht über dieses Array),
  # zusätzlich gegen permission_hash[:tm] abgesichert.
  def self.team_managers(team_id)
    User.not_archived
        .where('? = ANY(teams)', team_id)
        .where(active: true, receive_info_mails: true)
        .where.not(email: [nil, ''])
        .select { |u| u.permission_hash[:tm].to_a.include?(team_id) }
  end

  private

  # Fällig, sobald der Spielbericht abgeschlossen ist, die Liga Feedback aktiviert
  # hat und noch nicht benachrichtigt wurde.
  def due?
    @game.referee_feedback_notified_at.nil? &&
      @game.match_record_closed? &&
      @game.league&.referee_feedback_enabled?
  end
end
