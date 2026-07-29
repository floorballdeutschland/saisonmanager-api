# frozen_string_literal: true

# Benachrichtigt die Teammanager beider Mannschaften eines Spiels, dass das
# Schiri-Feedback-Formular ausfüllbar ist. Das Fenster öffnet, sobald der
# Spielbericht abgeschlossen ist (game_status match_record_closed/finalized).
#
# Hat eine Mannschaft einen Feedback-Kontakt hinterlegt (Kapitän*in des Spiels
# oder eine frei eingetragene Adresse, siehe RefereeFeedbackContact), geht
# zusätzlich eine Einladung mit Einmal-Link an diese Adresse. Die Teammanager
# bekommen ihre Info unabhängig davon (sofern sie Info-Mails nicht abbestellt
# haben): Die Abgabe bleibt Pflicht des Vereins, der Teammanager muss also
# einspringen können. Deshalb gehen sie ZUERST raus – Kontaktadressen sind
# selbst eingetragener Freitext, an dem der Versand scheitern kann.
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
  #
  # Wirft bewusst nicht: Ein einzelner fehlgeschlagener Versand darf weder den
  # Abschluss des Spielberichts zum Serverfehler machen noch im Cron-Fallback die
  # restlichen Spiele des Durchlaufs mitreißen. Fehler landen im Log, und das
  # Spiel wird trotzdem als benachrichtigt markiert, damit die erfolgreich
  # verschickten Mails beim nächsten Lauf nicht erneut rausgehen.
  def notify(deliver_now: false)
    return 0 unless due?

    mails = [@game.home_team, @game.guest_team].compact.sum do |team|
      notify_team_managers(team, deliver_now: deliver_now) +
        notify_contact(team, deliver_now: deliver_now)
    end

    @game.update_columns(referee_feedback_notified_at: Time.current)
    mails
  end

  # Teammanager der Mannschaft, die Info-Mails nicht abbestellt haben. `users.teams`
  # ist die TM-Team-Liste (VMs verwalten über den Verein, nicht über dieses Array),
  # zusätzlich gegen permission_hash[:tm] abgesichert. Das alte active-Flag wird
  # bewusst nicht mehr geprüft: Es ist seit der Archivierung nirgends mehr setzbar
  # und würde Bestandsnutzer mit active=false unsichtbar vom Versand ausschließen.
  def self.team_managers(team_id)
    User.not_archived
        .where('? = ANY(teams)', team_id)
        .where(receive_info_mails: true)
        .where.not(email: [nil, ''])
        .select { |u| u.permission_hash[:tm].to_a.include?(team_id) }
  end

  private

  # Einladung mit Einmal-Link an den Feedback-Kontakt der Mannschaft, sofern
  # einer auflösbar ist. Ein bereits abgegebenes Feedback (Nachlauf des
  # Rake-Fallbacks) braucht keine Einladung mehr.
  def notify_contact(team, deliver_now:)
    recipient = RefereeFeedbackContact.new(@game, team).resolve
    return 0 if recipient.nil?
    return 0 if RefereeFeedback.exists?(game: @game, team: team)

    invitation, raw_token = RefereeFeedbackInvitation.generate!(
      game: @game, team: team, email: recipient.email, player: recipient.player
    )
    deliver(
      RefereeFeedbackMailer.invitation(invitation, raw_token, source: recipient.source),
      deliver_now: deliver_now,
      context: "Einladung an #{recipient.email} (Spiel #{@game.id}, Team #{team.id})"
    )
  rescue StandardError => e
    log_failure("Einladung für Spiel #{@game.id}, Team #{team.id}", e)
    0
  end

  def notify_team_managers(team, deliver_now:)
    self.class.team_managers(team.id).sum do |tm|
      deliver(
        RefereeFeedbackMailer.form_available(tm, @game, team),
        deliver_now: deliver_now,
        context: "Teammanager-Info an Benutzer #{tm.id} (Spiel #{@game.id}, Team #{team.id})"
      )
    end
  end

  # Liefert 1 bei erfolgreichem Versand bzw. Einreihen, 0 bei einem Fehler. Der
  # Fehler wird geloggt statt geworfen (siehe notify). Bei deliver_now schlägt
  # ein abgelehnter Empfänger sofort auf (raise_delivery_errors ist in Produktion
  # aktiv), bei deliver_later erst im Job.
  def deliver(mail, deliver_now:, context:)
    deliver_now ? mail.deliver_now : mail.deliver_later
    1
  rescue StandardError => e
    log_failure(context, e)
    0
  end

  def log_failure(context, error)
    Rails.logger.warn("Schiri-Feedback-Mail fehlgeschlagen – #{context}: #{error.class}: #{error.message}")
    Sentry.capture_exception(error) if defined?(Sentry)
  end

  # Fällig, sobald der Spielbericht abgeschlossen ist, die Liga Feedback aktiviert
  # hat und noch nicht benachrichtigt wurde.
  def due?
    @game.referee_feedback_notified_at.nil? &&
      @game.match_record_closed? &&
      @game.league&.referee_feedback_enabled?
  end
end
