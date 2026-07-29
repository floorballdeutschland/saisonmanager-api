# frozen_string_literal: true

# Einmal-Link, über den eine Person ohne Benutzerkonto das Schiri-Feedback zu
# genau einem Spiel und genau einer Mannschaft abgeben kann. Gedacht für die
# Kapitänin oder den Kapitän einer Mannschaft bzw. die von der Mannschaft
# hinterlegte Feedback-Adresse (siehe RefereeFeedbackContact).
#
# Der Link ist die einzige Berechtigung, deshalb wird wie beim
# GameDaySecretaryLink nur der SHA256-Digest gespeichert; den Rohtoken gibt es
# ausschließlich beim Erzeugen zurück, um ihn zu verschicken.
class RefereeFeedbackInvitation < ApplicationRecord
  VALIDITY = 14.days

  belongs_to :game
  belongs_to :team
  belongs_to :player, optional: true

  validates :email, presence: true

  scope :unused, -> { where(used_at: nil) }

  def self.find_by_token(raw_token)
    return nil if raw_token.blank?

    find_by(token_digest: Digest::SHA256.hexdigest(raw_token))
  end

  # Erzeugt die Einladung für ein Spiel und eine Mannschaft und liefert
  # [invitation, raw_token]. Eine vorhandene Einladung wird ersetzt, damit nie
  # zwei Links für dieselbe Abgabe gültig sind (Unique-Index game_id+team_id).
  #
  # Löschen und Anlegen laufen in einer Transaktion: Bricht das Anlegen ab, wäre
  # sonst ein bereits verschickter, gültiger Link ersatzlos weg.
  def self.generate!(game:, team:, email:, player: nil)
    raw_token = SecureRandom.urlsafe_base64(32)

    invitation = transaction do
      where(game: game, team: team).destroy_all

      create!(
        game: game,
        team: team,
        player: player,
        email: email,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        expires_at: VALIDITY.from_now
      )
    end

    [invitation, raw_token]
  end

  def expired?
    expires_at.blank? || expires_at <= Time.current
  end

  def used?
    used_at.present?
  end

  def usable?
    !expired? && !used?
  end
end
