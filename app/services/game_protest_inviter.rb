# frozen_string_literal: true

# Verschickt die Upload-Links an die Protestparteien eines Spiels
# (Game#protest_parties). Läuft beim Abschluss des Spielberichts und, wenn
# danach eine Partei ergänzt wird, beim Speichern der Auswahl.
#
# Je Partei genau ein GameProtest und genau ein Link: Eine Partei, die schon
# einen hat, wird übergangen. Damit ist der Aufruf wiederholbar (ein erneut
# geöffneter und wieder abgeschlossener Bericht verschickt nichts doppelt).
# Wird eine Partei abgewählt, bleibt ihr Protest samt Formular erhalten; die
# SBK sieht ihn weiter.
#
# „other" (Andere) löst nichts aus, der Vorgang läuft dann manuell.
#
# Empfänger:
#   host      Vereinspost des Ausrichters (Club#notification_emails)
#   home/guest  Kaskade der Mannschaft (TeamContactRecipients)
#   referees  die angesetzten Schiedsrichter*innen mit Adresse, ein Link für beide
#
# Ohne Adresse wird der Protest trotzdem angelegt (recipients leer). Die SBK
# sieht in der Arbeitsansicht, dass kein Link zugestellt werden konnte.
class GameProtestInviter
  def initialize(game)
    @game = game
  end

  # Liefert die Anzahl neu angelegter Proteste.
  def call
    return 0 unless @game.protest?

    existing = @game.game_protests.pluck(:party)
    parties = Array(@game.protest_parties) - ['other'] - existing
    parties.count { |party| invite(party) }
  end

  def recipients_for(party)
    emails = case party
             when 'host' then @game.game_day&.club&.notification_emails.to_a
             when 'home' then team_recipients(@game.home_team)
             when 'guest' then team_recipients(@game.guest_team)
             when 'referees' then referee_emails
             else []
             end
    TeamContactRecipients.deliverable(emails)
  end

  private

  # Ein Fehler bei einer Partei darf weder die übrigen mitreißen noch den
  # gespeicherten Spielbericht zum Serverfehler machen.
  def invite(party)
    recipients = recipients_for(party)
    protest, token = GameProtest.create_with_token!(game: @game, party:, recipients:)

    if recipients.empty?
      Rails.logger.info("Protest: keine Adresse für Partei #{party} (Spiel #{@game.id})")
    else
      GameMailer.protest_upload_invitation(protest, token).deliver_later
    end
    true
  rescue StandardError => e
    Rails.logger.warn("Protest-Link für Partei #{party} (Spiel #{@game.id}) fehlgeschlagen: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
    false
  end

  def team_recipients(team)
    return [] if team.nil?

    TeamContactRecipients.for_team(team).last
  end

  def referee_emails
    assignment = @game.referee_assignment
    return [] unless assignment

    [assignment.referee1&.email, assignment.referee2&.email]
  end
end
