# Der Strafschuss wurde bis hierher über den Pseudo-Strafcode 23 markiert. Die
# id im Strafcode-Katalog ist aber nicht stabil: Beim Wechsel auf die 9xx-Codes
# wurde sie neu vergeben, seither liegt auf der 23 der Code 917 „Bodenspiel".
# Jede Strafe mit diesem Grund erschien dadurch als Strafschuss, also als Tor.
#
# Diese Migration trennt beide Bedeutungen in den Daten: Aus dem Pseudo-Code
# ohne Strafe wird die Torart `goal_type` „penalty_shot", der Code verschwindet.
# Ereignisse MIT `penalty_id` bleiben unangetastet -- das sind echte Strafen,
# deren Grund je nach Alter 917 („Bodenspiel") oder 806 („Strafschuss") heißt.
# Ihr Grund steht ohnehin eingefroren am Ereignis (siehe freeze_penalty_labels).
#
# Eigenes Minimalmodell und literale Werte statt Game und dessen Konstanten:
# Eine Migration muss auch in Jahren noch laufen (die Entwicklungsdatenbank wird
# über `rails db:migrate` aufgebaut, nicht aus einem Dump). Sie darf deshalb
# nicht davon abhängen, dass es die Klasse und ihre Konstanten dann noch gibt.
#
# `update_columns` statt `update`: keine Callbacks (Game#flush_league_caches),
# keine Validierung und vor allem kein neues `updated_at`. Letzteres ist hier
# nicht kosmetisch -- das Overlay nutzt `updated_at` als Version und lüde sonst
# für jedes der rund 2.800 Altspiele einmal die vollen Spieldaten nach.
class MarkPenaltyShotsWithGoalType < ActiveRecord::Migration[7.2]
  LEGACY_CODE = '23'.freeze
  GOAL_TYPE = 'penalty_shot'.freeze

  class MigrationGame < ActiveRecord::Base
    self.table_name = 'games'
  end

  def up
    convert(
      "e->>'penalty_code_id' = '#{LEGACY_CODE}' AND coalesce(e->>'penalty_id', '') = ''",
      ->(event) { event['penalty_code_id'].to_s == LEGACY_CODE && event['penalty_id'].blank? }
    ) do |event|
      event.delete('penalty_code_id')
      # `||=`: Ein technisches Tor mit anhängendem Pseudo-Code behält sein
      # Label. Beides zugleich ist nicht vorgesehen, kommt in Altdaten aber vor,
      # und die Reihenfolge der Zweige entschied dort schon immer für das
      # technische Tor.
      event['goal_type'] ||= GOAL_TYPE
      event
    end
  end

  # Rückwärts: die Torart wieder in den Pseudo-Code übersetzen. Nötig, falls die
  # Anwendung auf einen Stand vor dieser Änderung zurückgesetzt wird -- der
  # kennt die Torart „penalty_shot" nicht und wiese jeden Strafschuss als
  # gewöhnliches Tor aus.
  def down
    convert(
      "e->>'goal_type' = '#{GOAL_TYPE}'",
      ->(event) { event['goal_type'].to_s == GOAL_TYPE }
    ) do |event|
      event.delete('goal_type')
      event['penalty_code_id'] = LEGACY_CODE
      event
    end
  end

  private

  # `sql_filter` sucht die betroffenen Spiele, `match` dieselbe Bedingung noch
  # einmal je Ereignis -- die SQL-Zeile findet das Spiel, nicht das Ereignis.
  def convert(sql_filter, match)
    ids = select_values(<<~SQL.squish)
      SELECT DISTINCT g.id FROM games g, jsonb_array_elements(g.events) e
      WHERE jsonb_typeof(g.events) = 'array' AND #{sql_filter}
    SQL

    say "betroffene Spiele: #{ids.size}"
    converted = 0

    ids.each_slice(200) do |batch|
      MigrationGame.where(id: batch).each do |game|
        changed = false

        events = (game.events || []).map do |event|
          next event unless match.call(event)

          changed = true
          converted += 1
          yield event.dup
        end

        game.update_columns(events: events) if changed
      end
    end

    say "umgestellte Ereignisse: #{converted}"
  end
end
