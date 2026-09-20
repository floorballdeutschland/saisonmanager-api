# frozen_string_literal: true

# Erinnert den ausrichtenden Verein daran, die Spielberichtsbogen zu scannen –
# eine Stunde nach dem Spiel und nur, wenn bis dahin keiner hochgeladen wurde.
#
# Vorher ging die Mail im selben Augenblick raus, in dem der letzte
# Spielbericht des Spieltags geschlossen wurde (GamesController). Am Tisch wird
# der Bogen aber genau dann eingescannt: Der Ausrichter bekam die Erinnerung,
# während er die Datei schon auf dem Handy hatte, und wer sofort hochlud, wurde
# trotzdem erinnert. Jetzt ist es eine echte Erinnerung: Wer innerhalb der
# Stunde hochlädt, hört nichts.
#
# Gemessen wird ab dem Abschluss des letzten Spielberichts des Spieltags und
# nicht ab dem Schlusspfiff: Ein Spielende hält der Saisonmanager nirgends fest
# (`games.start_time` ist Text, ein Endzeitpunkt existiert nicht), und der
# Abschluss ist ohnehin der Moment, in dem der Bogen unterschrieben vorliegt.
#
# Versandweg ist der Cron-Lauf von `game_scans:remind`; ohne Eintrag in der
# Crontab geht keine Mail raus.
class GameDayScanReminder
  # Schonfrist zwischen Abschluss und Erinnerung.
  DELAY = 1.hour

  # Wie weit zurück überhaupt erinnert wird. Begrenzt den Altbestand beim
  # ersten Lauf: Ohne das Fenster wäre `scan_reminder_sent_at` für jeden je
  # gespielten Spieltag leer und der erste Cron-Lauf schriebe jeden Verein zu
  # jedem Spieltag der Vergangenheit an.
  LOOKBACK = 7.days

  CLOSED_STATUSES = %w[match_record_closed finalized].freeze

  # Nach so vielen Fehlversuchen wird aufgegeben. Bei stündlichem Lauf sind das
  # drei Stunden Nachsicht gegenüber einem vorübergehend gestörten Versand.
  MAX_ATTEMPTS = 3

  def self.notify_due(now: Time.current, dry_run: false)
    due(now: now).sum { |game_day| new(game_day).notify(now: now, dry_run: dry_run) }
  end

  # Die Spieltage, für die jetzt eine Erinnerung fällig ist. Die harten
  # Bedingungen stehen in SQL, die Feinprüfung (alle Spiele geschlossen, Scan
  # fehlt, Verband verlangt ihn) steht in Ruby: Sie hängt an
  # `effective_scan_required`, das die Vererbung der Verbandseinstellung
  # auflöst, und an der Vollständigkeit des Spieltags.
  def self.due(now: Time.current)
    GameDay
      .where(scan_reminder_sent_at: nil)
      .where(id: closed_long_enough(now))
      .includes(:club, { games: :game_scan }, league: { game_operation: :state_association })
      .select { |game_day| new(game_day).due?(now: now) }
  end

  def self.closed_long_enough(now)
    Game.where(game_status: CLOSED_STATUSES)
        .where(match_record_closed_at: (now - LOOKBACK)..(now - DELAY))
        .select(:game_day_id)
  end
  private_class_method :closed_long_enough

  def initialize(game_day)
    @game_day = game_day
  end

  def due?(now: Time.current)
    return false unless scan_required?
    return false unless recipients.any?

    games = @game_day.games.to_a
    return false if games.empty?
    # Ein Spieltag mit einem noch offenen Bericht ist nicht fertig: Die
    # Erinnerung nennt alle Spiele des Tages, und der offene kommt noch.
    return false unless games.all? { |game| CLOSED_STATUSES.include?(game.game_status) }
    return false unless games.any? { |game| game.game_scan.nil? }

    last_closed = games.filter_map(&:match_record_closed_at).max
    last_closed.present? && last_closed <= now - DELAY
  end

  # Verschickt die Erinnerung und hält den Versand fest. Gibt 1 zurück, wenn
  # eine Mail rausging, sonst 0.
  def notify(now: Time.current, dry_run: false)
    return 0 unless due?(now: now)
    return 1 if dry_run

    begin
      ClubMailer.game_day_scan_reminder(@game_day.club, @game_day).deliver_now
    rescue StandardError => e
      record_failure(e, now)
      return 0
    end

    @game_day.update_column(:scan_reminder_sent_at, now)
    1
  end

  private

  # Ein Fehlschlag darf die Erinnerung nicht dauerhaft löschen: Greylisting oder
  # ein kurz nicht erreichbarer Mailserver ist beim nächsten stündlichen Lauf
  # vorbei, und ohne einen zweiten Versuch verlöre der Ausrichter seine
  # Erinnerung an einem Zufall. Eine dauerhaft kaputte Adresse darf den Verein
  # aber auch nicht stündlich in denselben Fehler laufen lassen — nach
  # MAX_ATTEMPTS Versuchen wird der Spieltag gestempelt und die Aufgabe steht
  # im Log.
  def record_failure(error, now)
    versuche = @game_day.scan_reminder_attempts.to_i + 1
    aufgegeben = versuche >= MAX_ATTEMPTS

    updates = { scan_reminder_attempts: versuche }
    updates[:scan_reminder_sent_at] = now if aufgegeben
    @game_day.update_columns(updates)

    Rails.logger.warn(
      "Scan-Erinnerung für Spieltag #{@game_day.id} fehlgeschlagen " \
      "(Versuch #{versuche} von #{MAX_ATTEMPTS}#{', aufgegeben' if aufgegeben}): " \
      "#{error.class}: #{error.message}"
    )
    Sentry.capture_exception(error) if defined?(Sentry)
  end

  def scan_required?
    @game_day.league&.state_association&.effective_scan_required.present?
  end

  def recipients
    @game_day.club&.notification_emails.to_a
  end
end
