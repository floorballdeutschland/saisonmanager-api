# frozen_string_literal: true

# "Link zum Kalibrieren schicken" (fe#560): gestellt beim Beenden des
# Tabletmodus, verschickt vom Wächter (TabletHighlightLinks), sobald die
# Aufzeichnung fertig verarbeitet und veröffentlicht ist. Hat niemand einen
# angefordert, legt der Wächter ersatzweise Anfragen für die Konten an, mit
# denen am Tablet erfasst wurde (`fallback`, siehe TabletHighlightLinks).
#
# DATENSPARSAM: Angemeldete Personen bekommen die Mail an ihre Kontoadresse,
# gespeichert wird nur `user_id`. Eine eingegebene Adresse (Sekretariats-Link)
# steht nur bis zum Versand in `email` und wird dabei gelöscht. Unverschickte
# Anfragen verfallen nach PENDING_MAX_AGE, verschickte Links nach VALIDITY;
# beide räumt TabletHighlightLinks weg.
#
# Der Link ist die einzige Berechtigung. Wie bei RefereeFeedbackInvitation steht
# nur der SHA256-Digest in der Datenbank; der Rohtoken steht ausschließlich in
# der Mail.
#
# DER ROHTOKEN IST WIEDERHOLBAR: HMAC über `id` und `token_nonce` mit einem
# Schlüssel aus `secret_key_base`. Meldet der Mailserver nach der Annahme noch
# einen Fehler, schickt der nächste Lauf DENSELBEN Link; eine schon zugestellte
# erste Mail bleibt gültig. Die Datenbank allein reicht nicht, um ihn zu bilden.
class TabletHighlightRequest < ApplicationRecord
  VALIDITY = 14.days
  # Abgelaufene Links bleiben so lange stehen, damit die Seite "abgelaufen"
  # (410) statt "gibt es nicht" (404) sagen kann. Sie tragen dann keine Adresse
  # mehr, nur `user_id` und den Digest.
  EXPIRED_RETENTION = 30.days
  # Nach so vielen Fehlversuchen wird die Anfrage verworfen und gemeldet.
  MAX_SEND_ATTEMPTS = 5
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

  before_create { self.token_nonce ||= SecureRandom.hex(16) }

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

  def raw_token
    key = Rails.application.key_generator.generate_key('tablet_highlight_request_token')
    Base64.urlsafe_encode64(OpenSSL::HMAC.digest('SHA256', key, "#{id}:#{token_nonce}"), padding: false)
  end

  # Beansprucht die Anfrage atomar für den Versand: setzt Digest, `sent_at` und
  # Ablauf und löscht die eingegebene Adresse, aber nur, solange sie noch offen
  # ist. Liefert den Rohtoken oder nil, wenn ein anderer Lauf schneller war.
  # Innerhalb einer Transaktion hält Postgres die Zeile bis zum Commit; ein
  # paralleler Lauf wartet und findet danach nichts mehr.
  def claim!(now = Time.current)
    token = raw_token
    geaendert = self.class.where(id: id, sent_at: nil).update_all(
      token_digest: Digest::SHA256.hexdigest(token), sent_at: now, expires_at: now + VALIDITY, email: nil,
      updated_at: now
    )
    return nil unless geaendert == 1

    reload
    token
  end

  # Für Tests und den Weg ohne Wächter: beanspruchen oder scheitern.
  def issue_token!(now = Time.current)
    claim!(now) || raise(ActiveRecord::RecordNotSaved, 'Anfrage ist schon verschickt')
  end

  private

  def recipient_present
    errors.add(:email, 'fehlt') if recipient.blank?
  end
end
