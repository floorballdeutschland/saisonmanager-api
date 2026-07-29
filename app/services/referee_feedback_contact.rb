# frozen_string_literal: true

# Ermittelt, an wen die Einladung zum Schiri-Feedback einer Mannschaft geht.
# Hintergrund: Oft gibt nicht der Teammanager das Feedback ab, sondern die
# Kapitänin oder der Kapitän. Diese Personen sollen keinen eigenen Login
# bekommen, deshalb bekommen sie einen Einmal-Link (RefereeFeedbackInvitation).
#
# Reihenfolge:
#   1. Kapitän*in der Aufstellung DIESES Spiels, wenn die Mannschaft das so
#      eingestellt hat (teams.feedback_contact_prefer_captain) und am
#      Spielerprofil eine E-Mail-Adresse hinterlegt ist
#   2. die frei eingetragene Adresse teams.feedback_contact_email
#   3. niemand (nil) – dann bleibt es allein bei der Info an die Teammanager
#
# Die Kapitäns-Auflösung schlägt regelmäßig fehl, ohne dass etwas kaputt ist:
# Das Markieren im Spielbericht wird beim Abschluss nicht erzwungen, und
# Aufstellungseinträge ohne Spielerprofil (Freitext) haben keine player_id.
# Genau dafür ist Schritt 2 der Auffang.
class RefereeFeedbackContact
  Recipient = Struct.new(:email, :player, :source, keyword_init: true)

  def initialize(game, team)
    @game = game
    @team = team
  end

  def resolve
    captain_recipient || fallback_recipient
  end

  private

  def captain_recipient
    return nil unless @team.feedback_contact_prefer_captain?

    player = @game.captain_player(@team.id)
    email = player&.email.to_s.strip
    return nil if email.blank?

    Recipient.new(email: email, player: player, source: :captain)
  end

  def fallback_recipient
    email = @team.feedback_contact_email.to_s.strip
    return nil if email.blank?

    Recipient.new(email: email, player: nil, source: :team_contact)
  end
end
