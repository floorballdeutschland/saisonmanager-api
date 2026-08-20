# Entfernt Leerzeichen am Rand von Vorname/Nachname aus dem Bestand (api#496).
#
# HINTERGRUND
#
# Transfer/Freigabe verglich Namen bisher nur mit LOWER(), ohne TRIM(). Ein
# Profil mit einem Leerzeichen am Namensende (z.B. "Daniel ") fand darüber
# nie einen exakten Treffer, obwohl der abgebende oder aufnehmende Verein den
# richtigen Namen eingegeben hat. Player#strip_names verhindert das jetzt bei
# jedem Speichern; dieser Task räumt den Bestand einmalig auf.
#
# Kein Vorher-Nachher-Konflikt möglich: Zwei Profile mit identischem Vor-,
# Nachnamen und Geburtsdatum wären schon vor dem Trimmen ein exakter Treffer
# gewesen, das Trimmen ändert an dieser Auflösung nichts.
#
# AUFRUF
#
#   rake players:report_untrimmed_names   # nur lesend
#   rake players:trim_names               # Vorschau (Dry-Run, Default)
#   DRY_RUN=false rake players:trim_names  # ausführen
#
# Ein Lauf ist idempotent: Beim zweiten Mal findet er nichts mehr.

namespace :players do
  def players_trim_dry_run?
    ENV['DRY_RUN'] != 'false'
  end

  def players_untrimmed_scope
    Player.where('first_name <> TRIM(first_name) OR last_name <> TRIM(last_name)')
  end

  desc 'Zeigt Spielerprofile mit Leerzeichen am Rand von Vor- oder Nachname'
  task report_untrimmed_names: :environment do
    scope = players_untrimmed_scope
    puts "== Profile mit Leerzeichen am Namensrand: #{scope.count} =="
    scope.find_each do |player|
      puts "  #{player.id}\t#{player.first_name.inspect} #{player.last_name.inspect}"
    end
  end

  desc 'Trimmt Leerzeichen am Rand von Vor- und Nachname (Dry-Run per Default)'
  task trim_names: :environment do
    dry = players_trim_dry_run?
    puts dry ? '=== VORSCHAU (DRY_RUN) ===' : '=== SCHARF (DRY_RUN=false) ==='

    fixed = 0

    players_untrimmed_scope.find_each do |player|
      vorher = [player.first_name, player.last_name]
      nachher = [player.first_name.to_s.strip, player.last_name.to_s.strip]

      puts "  #{player.id}\t#{vorher.inspect} → #{nachher.inspect}"
      # update_columns statt save: der Bestand kann anderswo bereits ungueltig
      # sein (fehlende nation_id o.ae.), das darf das Trimmen nicht blockieren.
      player.update_columns(first_name: nachher[0], last_name: nachher[1]) unless dry
      fixed += 1
    end

    puts "\nGetrimmt: #{fixed}"
    puts "Nichts geschrieben. Mit DRY_RUN=false ausfuehren." if dry
  end
end
