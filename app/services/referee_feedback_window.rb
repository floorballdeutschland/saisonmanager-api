# frozen_string_literal: true

# Wann das Schiri-Feedback zu einem Spiel abgegeben werden darf.
#
# Zwei Bedingungen müssen zusammenkommen:
#
# 1. Der Spielbericht ist abgeschlossen (game_status match_record_closed/
#    finalized). Erst dann steht das tatsächlich eingesetzte Gespann fest, an das
#    das Feedback gehängt wird (Game#feedback_referees).
# 2. Der Anpfiff liegt mindestens FILLABLE_AFTER_HOURS Stunden zurück. Die Regel
#    lautet „24–48 h nach dem Spiel und keinesfalls vorher": Die Rückmeldung soll
#    mit Abstand zum Spiel entstehen, nicht in der Emotion direkt danach.
#
# Der Öffnungszeitpunkt ist damit das spätere der beiden Ereignisse. Ein Ende
# gibt es bewusst nicht: Die erwarteten 24 Stunden für die Abgabe stehen als
# Bitte im Seitentext und in der Mail, werden aber nicht erzwungen – eine spät
# abgegebene Rückmeldung ist wertvoller als keine.
#
# Genutzt von der Übersicht (UserRefereeFeedbacksController), von der Annahme
# beider Abgabewege (RefereeFeedbackSubmission) und vom Mailversand
# (RefereeFeedbackNotifier), damit Anzeige, Gate und Benachrichtigung nicht
# auseinanderlaufen.
class RefereeFeedbackWindow
  FILLABLE_AFTER_HOURS = 24

  def initialize(game)
    @game = game
  end

  # Öffnungszeitpunkt oder nil, wenn er sich nicht bestimmen lässt (Bericht offen,
  # oder weder Abschlusszeitpunkt noch Spieltagsdatum vorhanden).
  def opens_at
    return nil unless @game.match_record_closed?

    [@game.match_record_closed_at, earliest_after_game].compact.max
  end

  # Fehlt beides – Abschlusszeitpunkt und Spieltagsdatum – bleibt es beim
  # Bericht-Abschluss als einziger Bedingung. Sonst wären Altspiele ohne
  # gepflegtes Datum dauerhaft gesperrt.
  def open?
    return false unless @game.match_record_closed?

    at = opens_at
    at.nil? || at <= Time.current
  end

  private

  def earliest_after_game
    start = game_start
    start && start + FILLABLE_AFTER_HOURS.hours
  end

  # Anpfiff in lokaler Zeit. Fehlt nur die Uhrzeit, wird vom Tagesbeginn des
  # Spieltags gerechnet, damit ein Spiel ohne gepflegte Startzeit nicht crasht.
  #
  # game_days.date ist eine Textspalte. Das Datum wird deshalb strikt im Format
  # der Spalte geparst (wie TO_DATE(..., 'YYYY-MM-DD') in den Queries) und nicht
  # per Time.zone.parse über den Gesamtstring: Bei unbrauchbarem Inhalt würde
  # dieses aus „kein Datum 10:00" stillschweigend heute 10:00 Uhr machen und das
  # Fenster damit auf einen frei erfundenen Zeitpunkt legen.
  def game_start
    date = @game.game_day&.date
    return nil if date.blank?

    day = Date.strptime(date.to_s, '%Y-%m-%d')
    ActiveSupport::TimeZone['Europe/Berlin'].parse("#{day} #{@game.start_time}".strip)
  rescue ArgumentError, TypeError
    nil
  end
end
