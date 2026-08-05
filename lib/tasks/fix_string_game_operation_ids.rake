# lib/tasks/fix_string_game_operation_ids.rake
#
# Einmalige Reparatur von Spielbetriebs-Vermerken, die die ID als Text statt als
# Zahl führen (Stand 2026-08).
#
# Hintergrund: Die Vereinsanlage schrieb `params[:game_operation_id]` ungeprüft in
# den `game_operations_hash` – und params sind Strings. Alle Abfragen auf diesen
# Hash vergleichen per jsonb `@>` gegen eine Zahl
# (`GameOperation#home_clubs`, `#clubs`, `Club.admin_user_clubs`). Ein Text-Wert
# matcht dort nie: der Verein taucht in keiner Vereinsliste auf, auch nicht für
# verbandsübergreifende Zugriffe.
#
# Über die Oberfläche ist so ein Verein nicht mehr auffindbar und damit nicht
# reparierbar – das Bearbeiten-Formular erreicht man nur aus der Liste. Ein
# erneutes Speichern würde den Wert zwar richtigstellen, aber dazu muss man den
# Verein erst öffnen können.
#
# `Club#fix_game_operations_hash!` gibt es für genau diesen Fall schon, hatte
# aber keinen Aufrufer. Dieser Task ruft es für die betroffenen Vereine.
#
# Default Dry-Run. Scharfschalten mit DRY_RUN=false.

namespace :clubs do
  # Nur Vereine mit mindestens einem Text-Wert. jsonb_path_exists prüft den Typ
  # im Dokument selbst, statt alle Vereine in Ruby zu durchsuchen.
  #
  # Methode statt Konstante: Konstanten in einem rake-namespace-Block landen im
  # Top-Level-Namespace.
  def string_game_operation_id_sql
    %(jsonb_path_exists(game_operations_hash, '$[*].game_operation_id ? (@.type() == "string")'))
  end

  desc 'Repariert Spielbetriebs-Vermerke, deren ID als Text gespeichert ist ' \
       '(Default Dry-Run, DRY_RUN=false zum Ausfuehren)'
  task fix_string_game_operation_ids: :environment do
    dry_run = ENV.fetch('DRY_RUN', 'true') != 'false'
    affected = Club.where(string_game_operation_id_sql).order(:id)

    if affected.empty?
      puts 'Keine Vereine mit Text-IDs im Spielbetriebs-Vermerk – nichts zu tun.'
      next
    end

    puts dry_run ? '[DRY RUN] Folgende Vereine wuerden repariert:' : 'Folgende Vereine werden repariert:'

    repaired = 0
    affected.each do |club|
      vorher = club.game_operations_hash.map { |h| h['game_operation_id'].inspect }.join(', ')

      unless dry_run
        # fix_game_operations_hash! wandelt die Text-Werte in Zahlen und speichert.
        unless club.fix_game_operations_hash!
          abort "Verein #{club.id} (#{club.name}) konnte nicht gespeichert werden: " \
                "#{club.errors.full_messages.join(', ')}"
        end

        Rails.logger.info(
          "[clubs:fix_string_game_operation_ids] Club #{club.id} (#{club.name}): #{vorher} -> Zahlen"
        )
      end

      nachher = club.reload.game_operations_hash.map { |h| h['game_operation_id'].inspect }.join(', ') unless dry_run
      puts format('  %<id>-6s %<name>-34s %<vorher>s%<nachher>s',
                  id: club.id, name: club.name.to_s[0, 34], vorher: vorher,
                  nachher: dry_run ? '' : " -> #{nachher}")
      repaired += 1
    end

    puts "\n#{repaired} Verein(e) #{dry_run ? 'zu reparieren' : 'repariert'}."
    puts(dry_run ? "\n*** DRY RUN – ES WURDE NICHTS GESCHRIEBEN. Erneut mit DRY_RUN=false. ***" : '')
  end
end
