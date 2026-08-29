# frozen_string_literal: true

# Benachrichtigt die beobachteten Schiedsrichter*innen, dass eine neue
# Beobachtung vorliegt.
#
# Je Person eine eigene Mail und nicht eine an das Gespann: Im Portal sieht jede
# Person nur ihre eigenen Einzelbewertungen, ein gemeinsamer Verteiler würde das
# unterlaufen.
#
# Opt-out über users.receive_info_mails wie beim Vereins-Feedback. Wer kein
# Benutzerkonto hat, bekommt keine Mail – ohne Konto gibt es auch nichts zu
# lesen; die Rückmeldung geht dabei nicht verloren, sie wartet im Profil.
class RefereeObservationNotifier
  def initialize(observation)
    @observation = observation
  end

  # Liefert die Zahl der verschickten Mails.
  def deliver(deliver_now: false)
    recipients.count do |referee|
      mail = RefereeMailer.observation_available(referee, @observation)
      deliver_now ? mail.deliver_now : mail.deliver_later
      true
    end
  end

  private

  def recipients
    referee_ids = @observation.ratings.map(&:referee_id).uniq
    return [] if referee_ids.empty?

    notifiable_user_referee_ids = User.not_archived
                                      .where(referee_id: referee_ids, receive_info_mails: true)
                                      .pluck(:referee_id)
    Referee.where(id: notifiable_user_referee_ids).where.not(email: [nil, ''])
  end
end
