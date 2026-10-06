# Gültigkeitsfenster der Zugangslinks eines Spieltags (GameDaySecretaryLink,
# GameDayOverlayLink).
#
# Das Fenster hängt am SPIELTAG, nicht am Zeitpunkt des Erzeugens: Es beginnt
# LEAD_TIME vor dem Spieltag und endet am Ende des Tages danach, wie beim
# Lizenzlisten-Link (LicenseListLink). Vorher galten die Links eine feste Zeit
# ab dem Erzeugen (72 bzw. 36 Stunden). Wer den Zugang eine Woche vorher
# ausdruckte, hielt am Spieltag einen toten Zettel in der Hand (Feedback #70).
#
# Der Beginn ist kein Beiwerk: Ohne ihn wäre ein früh ausgedruckter Zettel ab
# dem Druck ein Schlüssel zu Lizenzlisten und Spielbericht und läge tagelang
# herum. 72 Stunden reichen, um den Zettel vor dem Spieltag einmal
# auszuprobieren, und sind nicht länger als bisher ein Sekretariatslink galt.
#
# Die Mindestdauer ab Ausgabe (`minimum_validity`) bleibt als Untergrenze: Wer
# den Zugang erst nach dem Spieltag erzeugt, um einen Bericht nachzutragen,
# bekäme sonst einen Link, der schon beim Erzeugen abgelaufen ist. Ohne lesbares
# Spieltagsdatum gilt allein sie, wie bisher.
module GameDayLinkWindow
  extend ActiveSupport::Concern

  # `game_days.date` ist Text ohne Zeitzone, die Anwendung läuft in UTC.
  # Gerechnet wird deshalb im Kalender des Spielbetriebs.
  ZONE = ActiveSupport::TimeZone['Europe/Berlin'].freeze
  LEAD_TIME = 72.hours

  included do
    # Nicht abgelaufen. Bewusst OHNE den Beginn: Die Übersichten sollen einen
    # früh erzeugten Zugang als bestehend zeigen, und eine Neuausgabe muss ihn
    # zurückziehen können.
    scope :active, -> { where('expires_at > ?', Time.current) }
  end

  class_methods do
    # Nur ein Link, der JETZT gilt. Alle Wege, die ein Token als Berechtigung
    # annehmen, gehen hierüber; ein noch nicht begonnener Link berechtigt zu
    # nichts.
    def find_by_token(raw_token)
      link = find_unexpired_by_token(raw_token)
      link if link&.started?
    end

    # Auch einen Link, dessen Fenster noch nicht begonnen hat. Nur für die
    # öffentlichen Einstiegsseiten, die dann „gilt erst ab" sagen können statt
    # „ungültig". Berechtigt zu nichts.
    def find_unexpired_by_token(raw_token)
      return nil if raw_token.blank?

      active.find_by(token_digest: Digest::SHA256.hexdigest(raw_token))
    end

    # [valid_from, expires_at] für die übergebenen Spieltage, ausgegeben zum
    # Zeitpunkt `issued_at`. Deckt ein Link mehrere Spieltage ab, reicht das
    # Fenster vom frühesten bis zum spätesten.
    def window_for(game_days, issued_at:)
      floor = issued_at + minimum_validity
      dates = Array(game_days).filter_map { |gd| parse_game_day_date(gd&.date) }
      return [issued_at, floor] if dates.empty?

      first = ZONE.local(dates.min.year, dates.min.month, dates.min.day)
      last = ZONE.local(dates.max.year, dates.max.month, dates.max.day)

      [first - LEAD_TIME, [last.next_day.end_of_day, floor].max]
    end

    # Nur das Format, das GameDay::DATE_FORMAT verlangt. Ein Altbestand in
    # anderer Schreibweise fällt auf die Mindestdauer zurück, statt mit
    # Date.parse womöglich falsch gelesen zu werden.
    def parse_game_day_date(raw)
      return nil unless raw.to_s.match?(GameDay::DATE_FORMAT)

      Date.iso8601(raw.to_s)
    rescue Date::Error
      nil
    end
  end

  # Altbestand vor dem Fenster hat keinen Beginn und gilt ab Ausgabe.
  def started?
    valid_from.nil? || valid_from <= Time.current
  end

  # Rechnet das Fenster neu, etwa wenn der Spieltag verschoben wurde. Ein
  # ausgedruckter Zettel bleibt damit gültig, statt am alten Termin zu
  # verfallen. Die Untergrenze rechnet ab der ursprünglichen Ausgabe, damit ein
  # Neuberechnen den Link nicht nebenbei verlängert.
  def refresh_window!
    valid_from, expires_at = self.class.window_for(window_game_days, issued_at: created_at)
    update_columns(valid_from: valid_from, expires_at: expires_at, updated_at: Time.current)
  end

  # Für Antworten an Nutzer: „Dieser Zugang gilt erst ab …".
  def not_started_message
    "Dieser Zugang gilt erst ab #{valid_from.in_time_zone(ZONE).strftime('%d.%m.%Y, %H:%M')} Uhr."
  end
end
