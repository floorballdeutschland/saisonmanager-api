# Jüngster Zeitpunkt, an dem sich an einem Spielbericht für die SBK etwas
# Neues ergeben hat. Daran misst die Arbeitsansicht „Spielberichte", ob ein
# Erledigt-Vermerk noch gilt (report_changed_since_review), und der Vermerk
# selbst, ob die SBK beim Abhaken den aktuellen Stand vor sich hatte
# (Admin::GameReportReviewsController, 409 bei veralteter Ansicht).
#
# Gezählt wird alles, was die SBK in der Zeile zu sehen bekommt:
# - Änderungen am Bericht (record_updated_at) und sein Abschluss
#   (match_record_closed_at),
# - der Einspruch des Ausrichters (checklist_veto_submitted_at),
# - Widersprüche von Gastmannschaft und Schiedsrichter (confirmed_at),
# - Papierbogen und Schiedsrichterbericht, jeweils updated_at: Ein ersetzter
#   Bericht hängt die neue Datei an denselben Datensatz, und ActiveStorage
#   berührt ihn dabei (touch_attachment_records),
# - die Anlage eines Verfahrensvorschlags. Seine späteren Statuswechsel sind
#   Schritte der Spielleitung selbst und zählen nicht.
#
# Der Erledigt-Vermerk selbst ist kein solcher Zeitpunkt, er läuft über
# update_columns und lässt record_updated_at stehen.
class GameReportLastChange
  # objection_times: Zeitpunkte der Widersprüche zum Spieltag, wenn der
  # Aufrufer sie schon für viele Spiele gemeinsam geladen hat (report_overview).
  # Ohne Angabe werden sie für dieses eine Spiel nachgeladen.
  def self.for(game, objection_times: nil)
    objection_times ||= objection_times_for(game.game_day_id)

    [
      game.record_updated_at,
      game.match_record_closed_at,
      game.checklist_veto_submitted_at,
      game.game_scan&.updated_at,
      game.game_referee_report&.updated_at,
      game.proceeding_proposal&.created_at,
      *objection_times
    ].compact.max
  end

  def self.objection_times_for(game_day_id)
    return [] if game_day_id.nil?

    GameDayTeamConfirmation.where(game_day_id:, properly_conducted: false).pluck(:confirmed_at) +
      GameDayRefereeConfirmation.where(game_day_id:, properly_conducted: false).pluck(:confirmed_at)
  end
end
