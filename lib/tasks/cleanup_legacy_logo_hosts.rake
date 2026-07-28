# lib/tasks/cleanup_legacy_logo_hosts.rake
#
# Datenkorrektur (Stand 2026-07): In den Textspalten game_operations.logo_url /
# .logo_quad_url standen absolute URLs mit eigenem Hostnamen, unter anderem auf
# api.saisonmanager.de. Dieser Host wirkt wie das neue System, fällt aber unter
# das DNS-Wildcard *.saisonmanager.de und zeigt weiter auf den ALT-Server.
#
# Warum das ein Fehler ist: Der Alt-Server liegt seit dem Domain-Umzug im Juli
# hinter einer globalen Basic Auth und antwortet mit 401 + `WWW-Authenticate:
# Basic`. Die Startseite lädt die Verbands-Logos als <img>; Browser, die
# Auth-Challenges von cross-origin Subresources nicht unterdrücken (Safari auf
# iOS/macOS, App-interne WebViews), zeigen dafür einen nativen Login-Dialog. Der
# ist wegklickbar, kommt aber bei jedem Aufruf der Startseite wieder.
#
# URLs auf die alte Domain saisonmanager.org sind nicht kaputt (sie laufen über
# den 301 auf .de), werden aber bei der Gelegenheit mitgekürzt, ebenso absolute
# URLs auf saisonmanager.de selbst.
#
# Die Dateien liegen im Repo unter public/verband/ und werden vom ausliefernden
# Server unter identischem Pfad bereitgestellt. Es genügt daher, den Host zu
# entfernen und den Pfad relativ zu speichern. Das entspricht den übrigen Zeilen
# (/api/storage/blobs/...) und übersteht künftige Domain-Wechsel. Preis dafür:
# Wer die API nicht von derselben Herkunft aus konsumiert, bekommt einen Pfad
# ohne Host und muss ihn selbst auflösen. Das ist gewollt.
#
# Der Task ist idempotent, ein zweiter Lauf ist ein No-Op.
#
#   rails cleanup:legacy_logo_hosts                 # Trockenlauf (Default)
#   rails cleanup:legacy_logo_hosts DRY_RUN=false   # schreibt
#
# Achtung: Im cleanup-Namespace gibt es beide Konventionen. Dieser Task und
# cleanup_stale_games.rake sind per Default Trockenlauf, cleanup:inactive_users
# und cleanup:old_transfer_requests schreiben per Default.
#
# Nur inventarisiert, nicht geändert werden die Link-Spalten (banner_link_url,
# live_stream_link, vod_link): Das sind von Hand eingetragene Verweisziele auf
# beliebige externe Seiten. Sie werden nicht als Subresource geladen, lösen beim
# Seitenaufbau also keinen Dialog aus (ein Klick kann weiterhin auf die Basic
# Auth des Alt-Servers laufen, das ist aber sichtbar und zuordenbar), und ein
# stilles Umschreiben würde ändern, wohin ein Banner zeigt.

namespace :cleanup do
  # -- Helpers ---------------------------------------------------------------

  # Absolute URLs auf eigene Hosts: Alt-Server (api.saisonmanager.de), alte
  # Domain (.org) und die aktuelle Domain (.de) selbst. Als Konstante im
  # namespace-Block würde RuboCop (Lint/ConstantDefinitionInBlock) anschlagen;
  # oberhalb des Blocks wäre sie global sichtbar und kollidiert quer über die
  # Rake-Dateien.
  #
  # Lookahead statt Match, damit der führende "/" erhalten bleibt und der
  # gespeicherte Pfad wurzelrelativ ist.
  def legacy_url_prefix_pattern
    %r{\Ahttps?://(?:api\.)?saisonmanager\.(?:de|org)(?=/)}i
  end

  # Spiegelt legacy_url_prefix_pattern für den DB-Filter und muss mit ihm
  # gemeinsam geändert werden. Bewusst nicht verankert: lieber eine Zeile zu
  # viel auswählen (wird dann als "nicht automatisch korrigierbar" gemeldet)
  # als eine zu wenig.
  def legacy_url_sql_pattern
    'https?://(api\.)?saisonmanager\.(de|org)/'
  end

  # Rand-Whitespace: Postgres' einargumentiges btrim() entfernt nur Leerzeichen,
  # nicht \r, \n oder Tabs. Ruby strip entfernt sie, deshalb hier ein
  # Regex-Vergleich statt btrim, sonst wären genau die \r\n-Zeilen nicht im Scope.
  def whitespace_sql_pattern
    '^\s|\s$'
  end

  # Spalten, die nur inventarisiert werden (Verweisziele, siehe Kopfkommentar).
  def legacy_link_columns
    [[GameOperation, :banner_link_url], [League, :banner_link_url],
     [StateAssociation, :banner_link_url], [Game, :live_stream_link], [Game, :vod_link]]
  end

  # Absolute Alt-URL auf einen relativen Pfad kürzen und Rand-Whitespace
  # entfernen (eine logo_quad_url endete auf "\r\n").
  def relativize_legacy_url(value)
    return value if value.blank?

    value.strip.sub(legacy_url_prefix_pattern, '')
  end

  def legacy_url_scope
    GameOperation.where(
      'logo_url ~* :re OR logo_quad_url ~* :re OR logo_url ~ :ws OR logo_quad_url ~ :ws',
      re: legacy_url_sql_pattern, ws: whitespace_sql_pattern
    )
  end

  # -- Task ------------------------------------------------------------------

  desc 'Kürzt absolute Logo-URLs der Spielbetriebe auf relative Pfade, entfernt Rand-Whitespace ' \
       'und inventarisiert Alt-Hosts in Link-Spalten. DRY_RUN=false zum Ausführen.'
  task legacy_logo_hosts: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== cleanup:legacy_logo_hosts #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    changes = []
    unfixable = []

    legacy_url_scope.each do |go|
      updates = %i[logo_url logo_quad_url].filter_map do |column|
        old_value = go.public_send(column)
        new_value = relativize_legacy_url(old_value)
        [column, old_value, new_value] if new_value != old_value
      end
      if updates.any?
        changes << [go, updates]
      else
        unfixable << go
      end
    end

    changes.each do |go, updates|
      puts "  #{go.short_name} (id #{go.id}):"
      updates.each { |column, old_value, new_value| puts "    #{column}: #{old_value.inspect} -> #{new_value.inspect}" }
      go.update!(updates.to_h { |column, _old, new_value| [column, new_value] }) unless dry_run
    end

    # Der DB-Filter ist unverankert, das Umschreiben greift nur am Anfang des
    # Werts. Solche Zeilen (z. B. Alt-Host als Query-Parameter) bleiben liegen
    # und werden benannt, damit "0 korrigiert" nicht mit "nichts zu tun"
    # verwechselt wird.
    unfixable.each do |go|
      puts "  Hinweis: #{go.short_name} (id #{go.id}) enthält einen Alt-Host, aber nicht am Anfang der URL, " \
           'bitte von Hand prüfen.'
    end

    message = if dry_run
                "[DRY RUN] #{changes.size} Spielbetriebe mit absoluter oder unsauberer Logo-URL würden korrigiert."
              else
                "#{changes.size} Spielbetriebe mit absoluter oder unsauberer Logo-URL korrigiert."
              end
    puts message
    puts '  Zum Ausführen: rails cleanup:legacy_logo_hosts DRY_RUN=false' if dry_run && changes.any?
    Rails.logger.info("[cleanup:legacy_logo_hosts] #{message}")

    # Inventar der Link-Spalten: bewusst nur Ausgabe, kein Schreiben (Begründung
    # im Kopfkommentar). unscoped, weil League#default_scope über order_key::int
    # sortiert und das die Aggregatabfrage bricht.
    legacy_link_columns.each do |model, column|
      count = model.unscoped.where("#{column} ~* :re", re: legacy_url_sql_pattern).count
      puts "  Hinweis: #{count} #{model.table_name}.#{column} mit Alt-Host (nur Verweisziel, bleibt unverändert)." if count.positive?
    end

    next if dry_run

    # Konvention bei Mutationen an init-Daten. ACHTUNG auf Produktion: der
    # cache_store ist :memory_store, also prozesslokal. Dieses delete räumt nur
    # den Cache des rake-Prozesses auf, nicht den der laufenden Puma-Worker.
    # Damit die Startseite die neuen URLs ausliefert, muss der rails-api-
    # Container neu starten oder die TTL (30 Minuten, plus 60 Sekunden
    # HTTP-Cache) ablaufen.
    Rails.cache.delete('settings/init')
    puts '  Cache settings/init im eigenen Prozess geleert. Auf Prod zusätzlich rails-api neu starten.'
  end
end
