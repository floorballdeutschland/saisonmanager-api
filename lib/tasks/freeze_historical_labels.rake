# lib/tasks/freeze_historical_labels.rake
#
# Einmalige Backfills, die historische Daten self-contained machen:
#   rake events:freeze_penalty_labels   – friert Straf-Labels in Spiel-Ereignisse ein
#   rake leagues:freeze_labels          – friert Klassen-/Kategorie-Namen + Punktekorrekturen an die Liga
#
# Beide unterstützen DRY_RUN=1 (nur zählen, nicht schreiben). Schreiben per
# update_columns, um Callbacks/Cache-Flushes/Validierungen zu umgehen – die
# eingefrorenen Werte entsprechen exakt der bisherigen Live-Auflösung, daher
# ändert sich an der Ausgabe nichts.

namespace :events do
  desc 'Friert Straf-Labels (Mapping/Name/Code/Beschreibung) in bestehende Spiel-Ereignisse ein (DRY_RUN=1 zum Testen)'
  task freeze_penalty_labels: :environment do
    dry_run = ENV['DRY_RUN'].present?
    changed = 0
    scanned = 0

    Game.find_each do |game|
      next if game.events.blank?

      scanned += 1
      before = game.events.map(&:dup)
      game.events.each { |event| Game.freeze_penalty_labels(event) }
      next if game.events == before

      changed += 1
      game.update_columns(events: game.events) unless dry_run # rubocop:disable Rails/SkipsModelValidations
    end

    puts "#{dry_run ? '[DRY_RUN] ' : ''}#{scanned} Spiele geprüft, #{changed} mit aktualisierten Straf-Labels."
  end
end

namespace :leagues do
  desc 'Friert Klassen-/Kategorie-Namen und Punktekorrekturen an die Liga (aus Setting) (DRY_RUN=1 zum Testen)'
  task freeze_labels: :environment do
    dry_run = ENV['DRY_RUN'].present?
    changed = 0

    League.find_each do |league|
      attrs = {}

      if league.league_class_name.blank? && league.league_class_id.present?
        name = Setting.league_class(league.league_class_id).presence
        attrs[:league_class_name] = name if name
      end

      if league.league_category_name.blank? && league.league_category_id.present?
        name = Setting.league_category(league.league_category_id).presence
        attrs[:league_category_name] = name if name
      end

      if league.point_corrections.blank?
        corrections = Setting.point_corrections(league.id)
        attrs[:point_corrections] = corrections if corrections.present?
      end

      next if attrs.empty?

      changed += 1
      league.update_columns(attrs) unless dry_run # rubocop:disable Rails/SkipsModelValidations
    end

    puts "#{dry_run ? '[DRY_RUN] ' : ''}#{changed} Ligen mit eingefrorenen Labels/Korrekturen aktualisiert."
  end
end
