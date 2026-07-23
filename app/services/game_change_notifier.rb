# frozen_string_literal: true

# Benachrichtigt bei relevanten Änderungen an einem Spiel (Anpfiff, Absage,
# Spieltagsdatum, Halle) die bereits informierten Beteiligten einer
# VERÖFFENTLICHTEN Personen-Ansetzung: die angesetzten Schiedsrichter, den
# Schiedsrichtercoach und den Ausrichter.
#
# Der Notifier ist selbst-abgesichert über den Zustand der Ansetzung. Aufrufer
# müssen daher nur entscheiden, ob sich ein relevantes Feld geändert hat (z. B.
# per Dirty-Tracking), nicht aber den Ansetzungsstatus prüfen.
#
# Bewusst KEINE Mail bei Vereins-Ansetzungen (club_assignment?), weil dort keine
# persönlich benachrichtigten Schiris existieren, und nur bei status 'published':
# vorläufige oder noch rohe Ansetzungen wurden den Beteiligten noch nicht
# kommuniziert, ihre Änderung soll also auch keine Update-Mail auslösen.
class GameChangeNotifier
  def self.notify(game)
    new(game).notify
  end

  def initialize(game)
    @game = game
  end

  # Verschickt die Update-Mails an Schiris, Coach und Ausrichter, sofern eine
  # veröffentlichte Personen-Ansetzung vorliegt. Andernfalls passiert nichts.
  def notify
    assignment = @game.referee_assignment
    return unless assignment&.status == 'published'
    return if assignment.club_assignment?

    # Format identisch zur Umbesetzungs-Mail (notify_published_lineup_change):
    # eine Update-Mail an jede/n angesetzte/n Schiri und den Coach, jeweils mit
    # der aktuellen Besetzung.
    official_names = assignment.referees.map { |r| "#{r.vorname} #{r.nachname}" }.join(', ')
    coach = assignment.coach

    [*assignment.referees, coach].compact.uniq(&:id).each do |referee|
      next if referee.email.blank?

      RefereeMailer.updated_assignment_notification(referee, @game, official_names, coach).deliver_later
    end

    return if @game.game_day.club&.contact_email.blank?

    GameDayMailer.updated_referees_to_host(@game).deliver_later
  end
end
