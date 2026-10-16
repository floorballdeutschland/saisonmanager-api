# frozen_string_literal: true

# Verknüpfung offizielles Tor <-> Tablet-Schuss (api#816).
#
# Das Tor wird regelgemäß erst mit dem Bully eingetragen, der Schuss dagegen im
# Moment des Tores angetippt. Beim Eintragen eines Tores wird deshalb der
# jüngste (nach `tapped_at`) noch nicht verknüpfte Tor-Schuss desselben Teams
# verknüpft. Passt das nicht, korrigiert das Tablet über
# GameShotsController#link.
#
# Ein Fehler hier darf das Eintragen des Tores nicht scheitern lassen: Das Tor
# ist gespeichert, wenn diese Methoden laufen, und der Spielbericht ist das
# Wichtigere. Er wird gemeldet, nicht geworfen.
module GameShotLinker
  module_function

  def link_new_goal(game, event)
    shot = game.game_shots.where(team: event[:event_team].to_s, result: 'goal', event_id: nil)
               .order(tapped_at: :desc, id: :desc).first
    return nil if shot.nil?

    shot.update!(event_id: event[:id].to_i)
    GameShotStats.flush!(game)
    shot
  rescue ActiveRecord::ActiveRecordError => e
    Sentry.capture_exception(e, extra: { game_id: game.id, event_id: event[:id] }) if defined?(Sentry)
    nil
  end

  def unlink_event(game, event_id)
    return if event_id.blank?

    geloest = game.game_shots.where(event_id: event_id.to_i).update_all(event_id: nil, updated_at: Time.current)
    GameShotStats.flush!(game) if geloest.positive?
  rescue ActiveRecord::ActiveRecordError => e
    Sentry.capture_exception(e, extra: { game_id: game.id, event_id: event_id }) if defined?(Sentry)
  end
end
