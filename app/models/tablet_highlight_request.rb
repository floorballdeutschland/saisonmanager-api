# frozen_string_literal: true

# "Link zum Kalibrieren schicken" (fe#560): gestellt beim Beenden des
# Tabletmodus, verschickt vom Wächter (TabletHighlightLinks), sobald die
# Aufzeichnung fertig verarbeitet und veröffentlicht ist.
#
# DATENSPARSAM: Angemeldete Personen bekommen die Mail an ihre Kontoadresse,
# gespeichert wird nur `user_id`. Eine eingegebene Adresse (Sekretariats-Link)
# steht nur bis zum Versand in `email` und wird dabei gelöscht. Unverschickte
# Anfragen verfallen nach PENDING_MAX_AGE, verschickte Links nach VALIDITY;
# beide räumt TabletHighlightLinks weg.
#
# Der Link ist die einzige Berechtigung. Wie bei RefereeFeedbackInvitation steht
# nur der SHA256-Digest in der Datenbank; der Rohtoken entsteht erst beim
# Versand und steht ausschließlich in der Mail.
class TabletHighlightRequest < ApplicationRecord
  VALIDITY = 14.days
  # Ein Stream, der zwei Wochen nach dem Spiel nicht veröffentlicht ist, wird
  # es in aller Regel nicht mehr.
  PENDING_MAX_AGE = 14.days
  # Höchstens so viele offene Anfragen je Spiel, damit ein weitergegebener
  # Sekretariats-Link keine Mailschleuder wird.
  MAX_PENDING_PER_GAME = 5

  belongs_to :game
  belongs_to :user, optional: true

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
  validate :recipient_present, on: :create

  scope :pending, -> { where(sent_at: nil) }

  def self.find_by_token(raw_token)
    return nil if raw_token.blank?

    find_by(token_digest: Digest::SHA256.hexdigest(raw_token.to_s))
  end

  def recipient
    email.presence || user&.email.presence
  end

  def expired?(now = Time.current)
    expires_at.blank? || expires_at <= now
  end

  # Erzeugt den Token, löscht die eingegebene Adresse und liefert den Rohtoken.
  def issue_token!(now = Time.current)
    raw_token = SecureRandom.urlsafe_base64(32)
    update!(token_digest: Digest::SHA256.hexdigest(raw_token), sent_at: now, expires_at: now + VALIDITY, email: nil)
    raw_token
  end

  private

  def recipient_present
    errors.add(:email, 'fehlt') if recipient.blank?
  end
end
