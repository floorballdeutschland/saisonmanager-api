# lib/tasks/cleanup_legacy_logo_hosts.rake
#
# Einmalige Datenkorrektur (Stand 2026-07): In den Textspalten
# game_operations.logo_url / .logo_quad_url standen noch absolute URLs auf den
# Alt-Server (api.saisonmanager.de) bzw. auf die frühere Domain
# saisonmanager.org.
#
# Warum das ein Fehler ist: Der Alt-Server liegt seit dem Domain-Umzug hinter
# einer globalen Basic Auth und antwortet mit 401 + `WWW-Authenticate: Basic`.
# Die Startseite lädt die Verbands-Logos als <img>; Browser, die
# Auth-Challenges von cross-origin Subresources nicht unterdrücken (Safari/iOS,
# App-interne WebViews), zeigen dafür einen nativen Login-Dialog. Der ist
# wegklickbar, kommt aber bei jedem Aufruf der Startseite wieder.
#
# Die Dateien liegen unter identischem Pfad auch auf dem neuen Server
# (/verband/... wird im Prod-vhost an Rails geproxyt). Es genügt daher, den Host
# zu entfernen und den Pfad relativ zu speichern. Das entspricht den übrigen
# Zeilen (/api/storage/blobs/...) und übersteht künftige Domain-Wechsel.
#
# DEFAULT Dry-Run. Scharfschalten mit DRY_RUN=false.
#
# Nur berichtet, nicht geändert werden Link-Spalten (banner_link_url,
# live_stream_link, vod_link): das sind Ziele von Verweisen, keine
# Subresources, und sie lösen keinen Dialog aus.

namespace :cleanup do
  # -- Helpers ---------------------------------------------------------------

  # Hosts, die auf das Alt-System bzw. die alte Domain zeigen. Als Konstante im
  # namespace-Block würde RuboCop (Lint/ConstantDefinitionInBlock) anschlagen.
  def legacy_url_prefix_pattern
    %r{\Ahttps?://(?:api\.)?saisonmanager\.(?:de|org)(?=/)}i
  end

  # Spalten, die nur inventarisiert werden (Verweisziele, keine Subresources).
  def legacy_link_columns
    [[GameOperation, :banner_link_url], [League, :banner_link_url],
     [StateAssociation, :banner_link_url], [Game, :live_stream_link], [Game, :vod_link]]
  end

  # Absolute Alt-URL auf einen relativen Pfad kürzen und Rand-Whitespace
  # entfernen (eine logo_quad_url endete auf "\r\n"). Gibt den unveränderten
  # Wert zurück, wenn nichts zu tun ist.
  def relativize_legacy_url(value)
    return value if value.blank?

    value.strip.sub(legacy_url_prefix_pattern, '')
  end

  # Betroffen sind Zeilen mit Alt-Host und solche mit Rand-Whitespace.
  def legacy_url_scope
    GameOperation.where(
      'logo_url ~* :re OR logo_quad_url ~* :re ' \
      'OR logo_url <> btrim(logo_url) OR logo_quad_url <> btrim(logo_quad_url)',
      re: legacy_url_sql_pattern
    )
  end

  def legacy_url_sql_pattern
    'https?://(api\.)?saisonmanager\.(de|org)/'
  end

  # -- Task ------------------------------------------------------------------

  desc 'Kürzt Alt-Server-Hosts in den Logo-URLs der Spielbetriebe auf relative Pfade. DRY_RUN=false zum Ausführen.'
  task legacy_logo_hosts: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'

    changes = legacy_url_scope.filter_map do |go|
      updates = %i[logo_url logo_quad_url].filter_map do |column|
        old_value = go.public_send(column)
        new_value = relativize_legacy_url(old_value)
        [column, old_value, new_value] if new_value != old_value
      end
      [go, updates] if updates.any?
    end

    changes.each do |go, updates|
      puts "  #{go.short_name} (id #{go.id}):"
      updates.each { |column, old_value, new_value| puts "    #{column}: #{old_value.inspect} -> #{new_value.inspect}" }
      go.update!(updates.to_h { |column, _old, new_value| [column, new_value] }) unless dry_run
    end

    message = if dry_run
                "[DRY RUN] #{changes.size} Spielbetriebe mit Alt-Host in Logo-URLs würden korrigiert."
              else
                "#{changes.size} Spielbetriebe mit Alt-Host in Logo-URLs korrigiert."
              end
    puts message
    Rails.logger.info("[cleanup:legacy_logo_hosts] #{message}")

    # Inventar der Link-Spalten: bewusst nur Ausgabe, kein Schreiben.
    legacy_link_columns.each do |model, column|
      count = model.unscoped.where("#{column} ~* :re", re: legacy_url_sql_pattern).count
      puts "  Hinweis: #{count} #{model.table_name}.#{column} mit Alt-Host (nur Verweisziel, bleibt unverändert)." if count.positive?
    end
  end
end
