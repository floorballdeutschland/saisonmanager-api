# frozen_string_literal: true

# Wann das Schiri-Feedback zu einem Spiel abgegeben werden darf.
#
# Zwei Bedingungen müssen zusammenkommen:
#
# 1. Der Spielbericht ist abgeschlossen (game_status match_record_closed/
#    finalized). Erst dann steht das tatsächlich eingesetzte Gespann fest, an das
#    das Feedback gehängt wird (Game#feedback_referees).
# 2. Der Anpfiff liegt mindestens FILLABLE_AFTER_HOURS Stunden zurück: Die
#    Rückmeldung soll mit Abstand zum Spiel entstehen, nicht in der Emotion
#    direkt danach. Ursprünglich waren das 24 Stunden; seit 09/2026 sind es 12,
#    damit ein Wochenendspieltag noch am selben Wochenende beantwortet werden
#    kann.
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
  FILLABLE_AFTER_HOURS = 12

  # Kalender des Spielbetriebs, siehe GameKickoff. Als Konstante hier belassen,
  # weil Aufrufer und Tests sie unter diesem Namen lesen: Wer sein Spiel auf
  # `Date.current` legt, baut zwischen 22:00 und 24:00 UTC ein Spiel von GESTERN
  # und wartet dann vergeblich darauf, dass die Sperrfrist noch greift.
  ZONE = GameKickoff::ZONE

  # Heute, aus Sicht des Spielbetriebs.
  def self.today
    GameKickoff.today
  end

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

  def game_start
    GameKickoff.at(@game)
  end
end
