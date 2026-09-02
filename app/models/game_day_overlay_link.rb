# Zugang für die Livestream-Overlays eines Spieltags (OBS-Browser-Quellen und
# Steuer-Dock). Nach demselben Muster wie GameDaySecretaryLink: gespeichert wird
# nur der SHA256-Digest, der Klartext existiert einmalig in der Antwort auf
# #generate!.
#
# Anders als ein API-Schlüssel mit Echtzeit-Freigabe gibt dieses Token
# ausschließlich die Spiele EINES Spieltags frei und läuft von selbst ab. Auf den
# Spieltag bezogen und nicht auf ein einzelnes Spiel, weil eine Übertragung in
# der Regel mehrere Partien hintereinander zeigt und das Dock ohne neues Token
# zwischen ihnen wechseln soll.
class GameDayOverlayLink < ApplicationRecord
  belongs_to :game_day
  belongs_to :created_by, class_name: 'User'

  # Reicht für Anwurf am Vorabend einrichten bis Abbau nach dem letzten Spiel.
  # Bewusst kürzer als beim Sekretariatslink (72 h): Das Token hebt die
  # Verzögerung für Live-Daten auf, es soll nicht länger gelten als die
  # Übertragung dauert.
  LIFETIME = 36.hours

  scope :active, -> { where('expires_at > ?', Time.current) }

  def self.find_by_token(raw_token)
    return nil if raw_token.blank?

    digest = Digest::SHA256.hexdigest(raw_token)
    active.find_by(token_digest: digest)
  end

  # Ein aktiver Link je Spieltag: Ein erneutes Erzeugen zieht den alten zurück.
  # Dasselbe Verhalten wie beim Sekretariatslink, damit ein versehentlich
  # weitergegebener Link über „neu erzeugen" entwertet werden kann.
  def self.generate!(game_day:, created_by:)
    raw_token = SecureRandom.urlsafe_base64(32)

    # Löschen und Anlegen gehören zusammen: Ohne Transaktion gibt es dazwischen
    # ein Fenster ohne Zugang, in dem die Übersicht „kein Zugang" meldet. Den
    # Doppelbestand verhindert erst der eindeutige Index auf game_day_id
    # (Migration 20260902110000); die Transaktion sorgt dafür, dass der zweite
    # gleichzeitige Versuch sauber zurückrollt statt halb fertig zu enden.
    link = transaction do
      where(game_day:).destroy_all

      create!(
        game_day: game_day,
        created_by: created_by,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        expires_at: LIFETIME.from_now
      )
    end

    [link, raw_token]
  end
end
