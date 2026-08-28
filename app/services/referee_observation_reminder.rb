# frozen_string_literal: true

# Erinnert den angesetzten Schiedsrichtercoach an seinen Beobachtungsbogen.
#
# Versandzeitpunkt ist der ANPFIFF, nicht das Spielende: Der Coach soll den
# Bogen schon während des Spiels aufschlagen können, um die Kriterien vor Augen
# zu haben. Das ist der bewusste Unterschied zum Vereins-Feedback, das erst 24 h
# nach dem Spiel öffnet, weil eine Mannschaft mit Abstand zum Ergebnis urteilen
# soll. Ein Coach beobachtet, er reagiert nicht.
#
# Nur angesetzte Coaches. Wer sich ein Spiel selbst aussucht (in Spielbetrieben
# ohne personenscharfe Ansetzung), bekommt keine Mail -- niemand weiß vorher,
# dass er hinfährt.
#
# Idempotent über referee_assignments.observation_reminder_sent_at.
class RefereeObservationReminder
  # Wie weit zurück der Lauf greift. Begrenzt den Altbestand beim ersten Lauf
  # und beim Nachlauf nach einem Cron-Ausfall, damit keine Mail-Flut entsteht.
  LOOKBACK_DAYS = 3

  # Ansetzungen, deren Spiel angepfiffen ist und deren Coach noch nicht erinnert
  # wurde. Die Zeitgrenze steht in SQL nur grob auf dem Tag; ob der Anpfiff
  # wirklich vorbei ist, entscheidet #due? je Datensatz, denn `start_time` ist
  # ein String und im Kalender des Spielbetriebs aufzulösen (GameKickoff).
  def self.due_assignments
    today = GameKickoff.today

    RefereeAssignment
      .where(status: 'published', observation_reminder_sent_at: nil)
      .where.not(coach_id: nil)
      .joins(game: :game_day)
      .includes(:coach, game: { game_day: :league })
      .where("TO_DATE(game_days.date, 'YYYY-MM-DD') BETWEEN ? AND ?",
             today - LOOKBACK_DAYS.days, today)
  end

  def initialize(assignment)
    @assignment = assignment
  end

  # Verschickt die Erinnerung, falls fällig, und markiert die Ansetzung. Gibt
  # die Anzahl versendeter Mails zurück (0 oder 1).
  #
  # Wirft bewusst nicht: Ein einzelner fehlgeschlagener Versand darf die
  # restlichen Ansetzungen des Cron-Durchlaufs nicht mitreißen. Der Fehler landet
  # im Log, die Ansetzung wird trotzdem markiert -- sonst versucht es der
  # nächste Lauf endlos erneut.
  def notify(deliver_now: false)
    return 0 unless due?

    sent = 0
    begin
      mail = RefereeMailer.observation_due(coach, game)
      deliver_now ? mail.deliver_now : mail.deliver_later
      sent = 1
    rescue StandardError => e
      Rails.logger.error(
        "RefereeObservationReminder Versand fehlgeschlagen: " \
        "assignment=#{@assignment.id} game=#{game&.id} #{e.class}: #{e.message}"
      )
    end

    @assignment.update_columns(observation_reminder_sent_at: Time.current)
    sent
  end

  # Fällig, sobald angepfiffen wurde -- und nur, solange es etwas zu erinnern
  # gibt: Wer den Bogen schon abgegeben hat, bekommt keine Mail mehr. Ohne
  # ermittelbaren Anpfiff wird NICHT erinnert, sondern gewartet; sonst ginge die
  # Mail für ein Spiel ohne gepflegtes Datum sofort raus, womöglich Wochen zu
  # früh.
  def due?
    # Die Marke auch hier prüfen und nicht nur im Scope: Sonst schickt ein
    # Direktaufruf erneut, und die Idempotenz hinge allein daran, dass jeder
    # Aufrufer den richtigen Scope benutzt.
    return false if @assignment.observation_reminder_sent_at.present?
    return false if coach.nil? || game.nil?
    return false unless notifiable_coach?

    kickoff = GameKickoff.at(game)
    return false if kickoff.nil? || kickoff > Time.current

    !RefereeObservation.exists?(game_id: game.id, coach_id: coach.id)
  end

  private

  def coach
    @assignment.coach
  end

  def game
    @assignment.game
  end

  # Eine Adresse am Schiedsrichterdatensatz muss da sein, und das zugehörige
  # Konto darf Info-Mails nicht abbestellt haben -- gleiche Regel wie beim
  # Vereins-Feedback. Ohne Konto gibt es keinen Weg, den Bogen auszufüllen;
  # dann ist die Mail nur ein Ärgernis.
  def notifiable_coach?
    return false if coach.email.blank?

    User.not_archived.exists?(referee_id: coach.id, receive_info_mails: true)
  end
end
