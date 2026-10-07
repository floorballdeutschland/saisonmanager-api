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
  include GameDayLinkWindow

  belongs_to :game_day
  belongs_to :created_by, class_name: 'User'

  # Mindestdauer ab Ausgabe, siehe GameDayLinkWindow. Das eigentliche Fenster
  # hängt am Spieltag und ist dasselbe wie beim Sekretariatslink. Früher galt
  # der Zugang bewusst kürzer (36 h ab Ausgabe), weil das Token die Verzögerung
  # für Live-Daten aufhebt. Vor dem Spieltag gibt es aber noch keine Live-Daten
  # und nach seinem Ende keine mehr, das längere Fenster gibt also nichts preis,
  # was nicht ohnehin öffentlich ist.
  LIFETIME = 36.hours

  def self.minimum_validity
    LIFETIME
  end

  # Ein aktiver Link je Spieltag: Ein erneutes Erzeugen zieht den alten zurück.
  # Dasselbe Verhalten wie beim Sekretariatslink, damit ein versehentlich
  # weitergegebener Link über „neu erzeugen" entwertet werden kann.
  def self.generate!(game_day:, created_by:)
    raw_token = SecureRandom.urlsafe_base64(32)
    valid_from, expires_at = window_for([game_day], issued_at: Time.current)

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
        valid_from: valid_from,
        expires_at: expires_at
      )
    end

    [link, raw_token]
  end

  def window_game_days
    [game_day]
  end
end
