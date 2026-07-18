# lib/tasks/renormalize_league_class_ids.rake
#
# Normalisiert nachträglich un-normalisierte league_class_id-Werte auf die
# kanonischen Codes (League::CODES) — vollständig analog zur einmaligen
# Normalisierungs-Migration #297, d. h. in EINEM Lauf:
#
#   1. leagues.league_class_id (Namensmuster > Wert-Mapping, sonst '')
#   2. die Lizenz-Kopien in players.licenses[].league_class_id — der Wert
#      folgt der Liga des Team (team_id -> league_id -> normalisierter Code);
#      Lizenzen ohne auflösbares Team/Liga fallen auf das Wert-Mapping zurück
#   3. Check (nur Report), ob die league_classes-Settings-Map die Code-Keys trägt
#
# Hintergrund (#119): Der finale Go-Live-Dump/Legacy-Import kam an Migration
# #297 vorbei — auf Prod tragen ~1977 Ligen (Saisons 6-17) und ~127k
# Lizenz-Kopien weiterhin Legacy-Werte. Ein Ligen-only-Lauf würde eine
# Inkonsistenz zu den Lizenz-Kopien erzeugen, daher normalisiert dieser Task
# beides zusammen. Idempotent: bereits kanonische Werte (und leere) werden
# übersprungen. Die Original-Werte sind nicht wiederherstellbar — Ausgabe
# als Deploy-Log sichern. Auf Prod detached starten (SSH-Abriss killt den Lauf).
#
# Dry-Run (Standard):
#   bundle exec rails leagues:renormalize_class_ids
# Ausführen:
#   bundle exec rails leagues:renormalize_class_ids DRY_RUN=false

namespace :leagues do
  desc 'Normalisiert league_class_id in Ligen UND Lizenz-Kopien (#114/#119). DRY_RUN=false zum Ausführen.'
  task renormalize_class_ids: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    suffix = dry_run ? ' [DRY RUN]' : ''
    puts "=== league_class_id normalisieren #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    # --- Schritt 1: Ligen -------------------------------------------------
    # Ziel-Codes aller Ligen in-memory merken (auch im Dry-Run), damit
    # Schritt 2 gegen den normalisierten Stand auflöst — wie in #297, wo die
    # Lizenz-Normalisierung nach der Ligen-Normalisierung lief.
    puts "\n--- Schritt 1: leagues.league_class_id"
    target_by_league = {}
    blanked = Hash.new { |h, k| h[k] = [] }
    leagues_changed = 0

    League.unscoped.find_each do |league|
      new_code = League.normalize_class_id(league.league_class_id, league.name)
      target_by_league[league.id] = new_code
      next if new_code == league.league_class_id.to_s

      leagues_changed += 1
      blanked[league.league_class_id] << "#{league.id} (S#{league.season_id}) #{league.name}" if new_code == ''
      puts "Liga ##{league.id} (S#{league.season_id}) #{league.name}: " \
           "'#{league.league_class_id}' → '#{new_code}'#{suffix}"

      league.update_columns(league_class_id: new_code) unless dry_run
    end

    blanked.sort.each do |old, leagues|
      puts "'#{old}' → '' (#{leagues.size} Ligen): #{leagues.first(5).join(' | ')}"
    end
    puts "Ergebnis Schritt 1: #{leagues_changed} Liga(en) normalisiert#{suffix}"

    # --- Schritt 2: Lizenz-Kopien in players.licenses ----------------------
    puts "\n--- Schritt 2: players.licenses[].league_class_id"
    class_by_team = Team.pluck(:id, :league_id).to_h { |tid, lid| [tid, target_by_league[lid]] }
    orphans = Hash.new(0)
    players_changed = 0
    licenses_changed = 0

    Player.find_each do |player|
      next if player.licenses.blank?

      changed = false
      licenses = player.licenses.map do |license|
        old = license['league_class_id'].to_s
        next license if old.blank? || League::CODES.include?(old)

        new_code = class_by_team[license['team_id'].to_i]
        if new_code.nil?
          new_code = League.normalize_class_id(old, nil)
          orphans[old] += 1
        end
        changed = true
        licenses_changed += 1
        license.merge('league_class_id' => new_code)
      end

      next unless changed

      players_changed += 1
      player.update_columns(licenses:) unless dry_run
    end

    orphans.sort.each do |old, count|
      puts "#{count} Lizenz(en) ohne auflösbares Team/Liga: '#{old}' per Wert-Mapping → " \
           "'#{League.normalize_class_id(old, nil)}'"
    end
    puts "Ergebnis Schritt 2: #{licenses_changed} Lizenz-Kopie(n) bei " \
         "#{players_changed} Spieler(n) normalisiert#{suffix}"

    # --- Schritt 3: Settings-Map (nur Report) ------------------------------
    puts "\n--- Schritt 3: league_classes-Settings-Map (Check)"
    keys = Setting.current&.league_classes&.keys || []
    if keys.sort == League::CODES.sort
      puts "OK: Settings-Map trägt die Code-Keys (#{keys.sort.join(', ')})"
    else
      puts "WARNUNG: Settings-Map-Keys weichen ab: #{keys.sort.join(', ')} — " \
           'erwartet werden die Codes aus League::CODES (Umschlüsselung wie #297, Block 3, nötig)'
    end

    puts "\n[DRY RUN] Zum Ausführen: rails leagues:renormalize_class_ids DRY_RUN=false" if dry_run
  end
end
