# frozen_string_literal: true

# Verknüpfung offizielles Tor <-> Tablet-Schuss (api#816).
#
# Das Tor wird regelgemäß erst mit dem Bully eingetragen, der Schuss dagegen im
# Moment des Tores angetippt. Gepaart werden Tor und Tor-Schuss, wenn Team und
# Abschnitt gleich sind; unter mehreren Kandidaten gewinnt der kleinste Abstand
# zwischen der Spielzeit des Schusses und der des Tores, ohne Spielzeit der
# älteste unverknüpfte. Das läuft in beide Richtungen: beim Eintragen eines
# Tores (#link_new_goal sucht den Schuss) und beim Anlegen nachgereichter
# Tor-Schüsse (#link_new_shots sucht das Tor). Passt es nicht, korrigiert das
# Tablet über GameShotsController#link.
#
# Ein Fehler hier darf das Eintragen des Tores nicht scheitern lassen: Das Tor
# ist gespeichert, wenn diese Methoden laufen, und der Spielbericht ist das
# Wichtigere. Er wird gemeldet, nicht geworfen.
#
# Freischläge (fe#589) werden nie gepaart, auch nicht über #link.
module GameShotLinker
  module_function

  def link_new_goal(game, event)
    team = event[:event_team].to_s
    periode = event[:period].to_i
    kandidaten = game.game_shots.shots.where(team: team, period: periode, result: 'goal', event_id: nil).to_a
    shot = naechster(kandidaten, sekunden(event[:time])) { |kandidat| [kandidat.game_time, kandidat.tapped_at] }
    return nil if shot.nil?

    shot.update_columns(event_id: event[:id].to_i, updated_at: Time.current)
    GameShotStats.flush!(game)
    shot
  rescue StandardError => e
    Sentry.capture_exception(e, extra: { game_id: game.id, event_id: event[:id] }) if defined?(Sentry)
    nil
  end

  # Nachgereichte Tor-Schüsse (Puffer nach Verbindungsabbruch): Das Tor ist
  # womöglich schon eingetragen. Ältere Schüsse zuerst, damit zwei Tore
  # desselben Abschnitts in ihrer Reihenfolge gepaart werden.
  def link_new_shots(game, shots)
    offen = shots.select { |shot| shot.shot? && shot.result == 'goal' && shot.event_id.nil? }
    return if offen.empty?

    vergeben = game.game_shots.linked.pluck(:event_id).to_set
    tore = game.formatted_events.select { |event| event[:event_type] == :goal }
    offen.sort_by(&:tapped_at).each do |shot|
      kandidaten = tore.select do |tor|
        !vergeben.include?(tor[:event_id].to_i) && tor[:event_team].to_s == shot.team &&
          tor[:period].to_i == shot.period
      end
      tor = naechster(kandidaten, sekunden(shot.game_time)) { |kandidat| [kandidat[:time], kandidat[:event_id].to_i] }
      next if tor.nil?

      shot.update_columns(event_id: tor[:event_id].to_i, updated_at: Time.current)
      vergeben << tor[:event_id].to_i
    end
    GameShotStats.flush!(game)
  rescue StandardError => e
    Sentry.capture_exception(e, extra: { game_id: game.id }) if defined?(Sentry)
  end

  def unlink_event(game, event_id)
    return if event_id.blank?

    geloest = game.game_shots.where(event_id: event_id.to_i).update_all(event_id: nil, updated_at: Time.current)
    GameShotStats.flush!(game) if geloest.positive?
  rescue StandardError => e
    Sentry.capture_exception(e, extra: { game_id: game.id, event_id: event_id }) if defined?(Sentry)
  end

  # Der Kandidat mit dem kleinsten Abstand der Spielzeit; ist keine
  # Bezugszeit bekannt oder fehlt sie dem Kandidaten, der älteste. Der Block
  # liefert [Spielzeit, Ordnungswert für "ältester"].
  def naechster(kandidaten, bezug)
    kandidaten.min_by do |kandidat|
      zeit, ordnung = yield(kandidat)
      sek = sekunden(zeit)
      abstand = bezug && sek ? (sek - bezug).abs : nil
      [abstand.nil? ? 1 : 0, abstand || 0, ordnung]
    end
  end

  # "12:34" -> 754, sonst nil.
  def sekunden(zeit)
    treffer = zeit.to_s.match(/\A(\d{1,3}):(\d{2})\z/)
    treffer && ((treffer[1].to_i * 60) + treffer[2].to_i)
  end
end
