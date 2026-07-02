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
      game.update_columns(events: game.events) unless dry_run
    end

    puts "#{dry_run ? '[DRY_RUN] ' : ''}#{scanned} Spiele geprüft, #{changed} mit aktualisierten Straf-Labels."
  end
end

namespace :penalty_codes do
  desc 'Friert Alt-Straf-Gründe (name-only Codes) in Events ein und entfernt die verwaisten Katalog-Einträge (DRY_RUN=1 zum Testen)'
  task cleanup_legacy: :environment do
    dry_run = ENV['DRY_RUN'].present?
    setting = Setting.current
    codes = (setting.penalty_codes || {}).deep_dup

    # Alt-Codes: nur eine Bezeichnung ('name'), kein 3-stelliger 'code', nicht aktiv.
    legacy = codes.select do |_id, v|
      next false unless v.is_a?(Hash)

      active = [true, 'true'].include?(v['active'])
      v['name'].present? && v['code'].blank? && !active
    end
    legacy_ids = legacy.keys

    if legacy_ids.empty?
      puts 'Keine Alt-Codes (name-only) gefunden – nichts zu tun.'
      next
    end
    puts "Alt-Codes: #{legacy_ids.map { |id| "#{id}=#{codes[id]['name']}" }.join(', ')}"

    # 1) Nur Spiele einfrieren, die einen Alt-Code referenzieren.
    frozen_games = 0
    unfreezable = 0
    Game.find_each do |game|
      next if game.events.blank?
      next unless game.events.any? { |e| legacy_ids.include?(e['penalty_code_id'].to_s) }

      before = game.events.map(&:dup)
      game.events.each do |event|
        Game.freeze_penalty_labels(event)
        next unless legacy_ids.include?(event['penalty_code_id'].to_s)

        unfreezable += 1 if event['penalty_code_description'].to_s.strip.empty?
      end

      next if game.events == before

      frozen_games += 1
      game.update_columns(events: game.events) unless dry_run
    end
    puts "#{dry_run ? '[DRY_RUN] ' : ''}#{frozen_games} Spiele mit eingefrorenen Alt-Straf-Gründen."

    # 2) Sicherung: kein Alt-Code-Event darf ohne eingefrorene Beschreibung bleiben.
    if unfreezable.positive?
      abort "ABBRUCH: #{unfreezable} Alt-Code-Events lassen sich nicht einfrieren – Katalog NICHT verändert."
    end

    # 3) Verwaiste Katalog-Einträge entfernen (Grund bleibt in den Events erhalten).
    legacy_ids.each { |id| codes.delete(id) }
    if dry_run
      puts "[DRY_RUN] Würde Katalog-Einträge entfernen: #{legacy_ids.join(', ')}"
    else
      setting.penalty_codes = codes
      setting.save! # after_commit :flush_caches invalidiert settings/current + settings/init
      puts "Entfernte Katalog-Einträge: #{legacy_ids.join(', ')}"
    end
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
      league.update_columns(attrs) unless dry_run
    end

    puts "#{dry_run ? '[DRY_RUN] ' : ''}#{changed} Ligen mit eingefrorenen Labels/Korrekturen aktualisiert."
  end
end
