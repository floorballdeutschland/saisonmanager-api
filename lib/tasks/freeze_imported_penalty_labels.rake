# lib/tasks/freeze_imported_penalty_labels.rake
#
#   rake events:freeze_imported_penalty_labels   (DRY_RUN=1 zum Testen)
#
# Einmaliger Backfill für die aus dem Alt-/Archivsystem importierten Spiele
# (Saisons 2–17). Deren Ereignisse speichern `penalty_id`/`penalty_code_id` als
# Schlüssel des DAMALIGEN Katalogs. Der heutige Setting-Katalog wurde inzwischen
# neu nummeriert bzw. auf ein neueres Regelwerk umgestellt, weshalb diese Events
# ohne eingefrorenes Label falsch aufgelöst werden (z. B. 10' wird als „5 Minuten",
# „Unsportliches Verhalten" als „Verlassen des Torraums" angezeigt).
#
# Der Task friert die KORREKTEN historischen Labels (aus dem Archiv-Katalog,
# unten fest hinterlegt) direkt ins Event-JSONB ein: penalty_mapping, penalty_name,
# penalty_code, penalty_code_description. Die Anzeige (Game#penalty_mapping_string,
# #penalty_reason) und die Straf-Statistik (#penalty_mapping) bevorzugen diese
# eingefrorenen Werte, sind danach also katalog-unabhängig und historisch treu.
#
# Nicht-destruktiv: die rohen `penalty_id`/`penalty_code_id` bleiben unverändert,
# es werden nur die Label-Schlüssel ergänzt. Idempotent: bereits eingefrorene
# Events (penalty_mapping gesetzt) werden übersprungen – schützt native, im
# aktuellen System erfasste Einträge, die per Game.freeze_penalty_labels bereits
# mit dem heutigen Katalog eingefroren wurden.
#
# WICHTIG: NICHT den generischen `events:freeze_penalty_labels`-Task auf diesen
# Alt-Bestand loslassen – der löst über Setting.current auf und würde die FALSCHEN
# Labels dauerhaft einbrennen. Dieser Task hier ist der maßgebliche für Alt-Daten.

namespace :events do
  desc 'Friert korrekte historische Straf-Labels (Archiv-Katalog) in importierte Alt-Ereignisse ein (DRY_RUN=1 zum Testen)'
  task freeze_imported_penalty_labels: :environment do
    dry_run = ENV['DRY_RUN'].present?

    # Archiv-Katalog (fd-saisonmanager01). Die importierten Events verweisen auf
    # DIESE Schlüssel. `mapping`-Symbole sind mit dem heutigen Katalog identisch,
    # daher zählt die Statistik korrekt weiter.
    archive_penalties = {
      '1' => { 'mapping' => 'penalty_2',       'name' => "2'" },
      '2' => { 'mapping' => 'penalty_5',       'name' => "5'" },
      '3' => { 'mapping' => 'penalty_10',      'name' => "10'" },
      '4' => { 'mapping' => 'penalty_ms1',     'name' => 'M I' },
      '5' => { 'mapping' => 'penalty_ms2',     'name' => 'M II' },
      '6' => { 'mapping' => 'penalty_ms3',     'name' => 'M III' },
      '7' => { 'mapping' => 'penalty_2and2',   'name' => '2+2' },
      '8' => { 'mapping' => 'penalty_ms_tech', 'name' => 't. MS' },
      '9' => { 'mapping' => 'penalty_ms_full', 'name' => 'MS' }
    }.freeze

    archive_codes = {
      '1'  => { 'code' => 901, 'description' => 'Stockschlag' },
      '2'  => { 'code' => 902, 'description' => 'Blockieren des Stocks' },
      '3'  => { 'code' => 903, 'description' => 'Anheben des Stocks' },
      '4'  => { 'code' => 904, 'description' => 'Hoher Stock' },
      '5'  => { 'code' => 905, 'description' => 'Stock / Schläger zw. Beine' },
      '6'  => { 'code' => 906, 'description' => 'Haken' },
      '7'  => { 'code' => 907, 'description' => 'Stoßen' },
      '8'  => { 'code' => 908, 'description' => 'Überharter Körpereinsatz' },
      '9'  => { 'code' => 909, 'description' => 'Überharter Körpereinsatz' },
      '10' => { 'code' => 910, 'description' => 'Halten' },
      '11' => { 'code' => 911, 'description' => 'Sperren' },
      '12' => { 'code' => 913, 'description' => 'Hoher Fuß' },
      '13' => { 'code' => 915, 'description' => 'unkorrekter Abstand' },
      '14' => { 'code' => 919, 'description' => 'Bodenspiel' },
      '15' => { 'code' => 920, 'description' => 'Handspiel' },
      '16' => { 'code' => 921, 'description' => 'Kopfspiel' },
      '17' => { 'code' => 922, 'description' => 'Wechselfehler' },
      '18' => { 'code' => 923, 'description' => 'Wiederholte Vergehen' },
      '19' => { 'code' => 924, 'description' => 'Spielverzögerung' },
      '20' => { 'code' => 925, 'description' => 'Reklamieren' },
      '21' => { 'code' => 950, 'description' => 'Unsportliches Verhalten' },
      '22' => { 'code' => 999, 'description' => 'sonst. Vergehen' },
      '23' => { 'code' => 806, 'description' => 'Strafschuss' }
    }.freeze

    scanned_games = 0
    changed_games = 0
    frozen_events = 0
    already_frozen = 0
    unresolved_penalty = Hash.new(0)
    unresolved_code = Hash.new(0)
    by_name = Hash.new(0)

    Game.find_each do |game|
      next if game.events.blank?

      scanned_games += 1
      game_changed = false

      game.events.each do |event|
        next unless event.is_a?(Hash)
        next if event['penalty_id'].blank? # kein Straf-Ereignis

        if event['penalty_mapping'].present?
          already_frozen += 1
          next # bereits eingefroren -> idempotent, schützt native Einträge
        end

        penalty = archive_penalties[event['penalty_id'].to_s]
        unless penalty
          # z. B. penalty_id '0' – nicht auflösbar, unverändert lassen
          unresolved_penalty[event['penalty_id'].to_s] += 1
          next
        end

        event['penalty_mapping'] = penalty['mapping']
        event['penalty_name'] = penalty['name']

        if event['penalty_code_id'].present?
          code = archive_codes[event['penalty_code_id'].to_s]
          if code
            event['penalty_code'] = code['code']
            event['penalty_code_description'] = code['description']
          else
            # verirrte Roh-Codenummer o. Ä. – Dauer bleibt eingefroren, Grund offen
            unresolved_code[event['penalty_code_id'].to_s] += 1
          end
        end

        frozen_events += 1
        by_name[penalty['name']] += 1
        game_changed = true
      end

      next unless game_changed

      changed_games += 1
      # update_columns umgeht Callbacks/Validierungen/Cache-Flushes: wir ergänzen
      # nur Label-Schlüssel, die Live-Auflösung der Roh-IDs bleibt unberührt.
      game.update_columns(events: game.events) unless dry_run
    end

    prefix = dry_run ? '[DRY_RUN] ' : ''
    puts "#{prefix}#{scanned_games} Spiele geprüft, #{changed_games} aktualisiert, #{frozen_events} Straf-Events eingefroren."
    puts "#{prefix}Bereits eingefrorene (übersprungene) Straf-Events: #{already_frozen}."
    puts "#{prefix}Verteilung nach Dauer: #{by_name.sort_by { |_k, v| -v }.map { |k, v| "#{k}=#{v}" }.join(', ')}"
    unless unresolved_penalty.empty?
      puts "#{prefix}WARN nicht auflösbare penalty_id (unverändert): #{unresolved_penalty.map { |k, v| "#{k}=#{v}" }.join(', ')}"
    end
    unless unresolved_code.empty?
      puts "#{prefix}WARN nicht auflösbare penalty_code_id (Dauer eingefroren, Grund offen): #{unresolved_code.map { |k, v| "#{k}=#{v}" }.join(', ')}"
    end
  end
end
