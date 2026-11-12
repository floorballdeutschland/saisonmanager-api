# frozen_string_literal: true

# Ein Protest einer Partei zu einem Spiel (Game#protest_parties). Die Partei
# bekommt beim Abschluss des Spielberichts einen Einmal-Link
# (GameProtestInviter) und lädt darüber ohne Anmeldung das Protestformular
# hoch (ProtestsController). Das Formular bleibt hier gespeichert; die SBK
# sieht es in der Arbeitsansicht „Spielberichte" und bekommt es per Mail.
#
# Der Link ist die einzige Berechtigung. Wie bei RefereeFeedbackInvitation wird
# nur der SHA256-Digest gespeichert, den Rohtoken gibt es ausschließlich beim
# Erzeugen. Eine technische Frist gibt es bewusst nicht (Entscheidung
# 12.11.2026): Fristen prüft die SBK anhand von submitted_at. Der Link gilt,
# bis ein Formular hochgeladen ist.
class GameProtest < ApplicationRecord
  include PdfOnlyAttachment

  MAX_FILE_SIZE = 5.megabytes

  belongs_to :game
  has_one_attached :file

  validates :party, inclusion: { in: Game::PROTEST_PARTIES - ['other'] }
  validates :token_digest, presence: true
  validate :acceptable_file

  def self.find_by_token(raw_token)
    return nil if raw_token.blank?

    find_by(token_digest: Digest::SHA256.hexdigest(raw_token))
  end

  # Legt den Protest einer Partei an und liefert [protest, raw_token].
  def self.create_with_token!(game:, party:, recipients:)
    raw_token = SecureRandom.urlsafe_base64(32)
    protest = create!(game:, party:, recipients:, invited_at: Time.current,
                      token_digest: Digest::SHA256.hexdigest(raw_token))
    [protest, raw_token]
  end

  def submitted?
    submitted_at.present?
  end

  def party_label
    game.protest_party_label(party)
  end

  private

  def acceptable_file
    validate_pdf_attachment(:file, max_size: MAX_FILE_SIZE)
  end
end
