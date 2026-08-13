require 'open3'

# Kennzahlen zum Betriebszustand des Servers, vor allem zum Speicherplatz.
#
# Hintergrund: Seit dem Wegfall der Azure-Anbindung liegen alle Uploads
# (Lizenzdokumente, Vereins-, Verbands- und Ligalogos) über den ActiveStorage-
# Disk-Service lokal auf der Serverplatte. Der Bestand wächst monoton und fällt
# niemandem auf, solange nichts kaputt ist.
#
# Dieses Modul misst den Datenträger und setzt die Antwort für die Admin-Seite
# zusammen. Was den Platz belegt, erhebt SystemHealth::Inventory; wann gewarnt
# wird, entscheidet SystemHealth::DailyCheck.
#
# Bewusste Grenzen:
# - Das Postgres-Datenverzeichnis liegt in einem eigenen Docker-Volume und ist
#   aus dem API-Container nicht sichtbar. Statt einer Platten-Kennzahl gibt es
#   deshalb die Datenbankgröße per pg_database_size.
# - Es gibt keine CPU-/RAM-Werte. Der Server ist ein einzelner Host, die
#   Momentaufnahme in einem Request hätte keinen Aussagewert.
module SystemHealth
  # Ampelschwellen in Prozent Belegung. An einer Stelle, damit Seite, Job und
  # Tests dieselben Grenzen verwenden.
  WARNING_PERCENT = 80
  CRITICAL_PERCENT = 90

  # Reihenfolge von harmlos nach kritisch. Der Job vergleicht Zustände darüber,
  # damit nur eine Verschlechterung erneut warnt.
  STATUSES = %w[ok warning critical unknown].freeze

  # Monate, über die das Wachstum gemittelt wird. Kürzer wäre zu zufällig
  # (Lizenzanträge kommen saisonal in Wellen), länger würde eine Änderung im
  # Uploadverhalten zu lange nachwirken.
  FORECAST_MONTHS = 6

  # Anzahl der Monate in der Wachstumstabelle der Admin-Seite.
  HISTORY_MONTHS = 12

  # Der tägliche Job schreibt die Belegung als Tageswert mit. Damit gibt es zum
  # einen einen echten Verlauf für die Admin-Seite (nicht nur die aus den
  # Uploads gerechnete Schätzung), zum anderen braucht die Frühwarnung keinen
  # eigenen Merker: Der letzte gemessene Tag ist der Vergleichswert dafür, ob
  # sich der Zustand verschlechtert hat.
  DISK_METRIC_KEY = 'system_disk_used_percent'.freeze

  # Tage, über die der gemessene Verlauf auf der Admin-Seite gezeigt wird.
  HISTORY_DAYS = 60

  class << self
    def report
      disk = uploads_disk

      {
        generated_at: Time.current.iso8601,
        status: overall_status(disk),
        thresholds: { warning_percent: WARNING_PERCENT, critical_percent: CRITICAL_PERCENT },
        disk: disk.merge(history: disk_history),
        uploads: Inventory.uploads,
        database: Inventory.database,
        growth: Inventory.growth(disk[:free_bytes]),
        operations: operations
      }
    end

    # Gemessener Verlauf der Belegung. Leer, solange der tägliche Job noch nicht
    # gelaufen ist – die Seite funktioniert auch dann, sie zeigt nur keinen Verlauf.
    def disk_history
      from = Date.current - (HISTORY_DAYS - 1)
      DailyMetric
        .where(metric_key: DISK_METRIC_KEY, date: from..Date.current)
        .order(:date)
        .pluck(:date, :count)
        .map { |date, percent| { date: date.to_s, used_percent: percent } }
    end

    # Belegung des Datenträgers, auf dem die Uploads liegen. Im Container ist das
    # ein Bind-Mount, `df` liefert dort die Werte des Host-Volumes – genau die
    # Zahl, die interessiert.
    def uploads_disk
      path = uploads_path
      return { status: 'unknown', reason: 'no_disk_service' } if path.nil?

      # Vor dem ersten Upload existiert das Verzeichnis noch nicht. Gemessen wird
      # dann der nächste vorhandene übergeordnete Pfad – das ist derselbe
      # Datenträger, auf dem die Uploads später landen.
      usage = disk_usage(existing_ancestor(path))
      return { status: 'unknown', reason: 'df_failed', path: path.to_s } if usage.nil?

      usage.merge(
        path: path.to_s,
        status: status_for_percent(usage[:used_percent])
      )
    end

    # Nur der Disk-Service hat ein lokales Verzeichnis. Läuft ActiveStorage
    # wieder gegen einen Cloud-Dienst, gibt es hier nichts zu messen.
    def uploads_path
      service = ActiveStorage::Blob.service
      return nil unless service.respond_to?(:root)

      Pathname.new(service.root)
    rescue StandardError => e
      Rails.logger.error("SystemHealth#uploads_path failed: #{e.class}: #{e.message}")
      nil
    end

    def existing_ancestor(path)
      candidate = path
      candidate = candidate.parent while !candidate.exist? && !candidate.root?
      candidate
    end

    # `df -Pk` in POSIX-Ausgabe, ein Datensatz pro Zeile, Werte in KiB. Der Pfad
    # kommt aus der Rails-Konfiguration, nicht aus Nutzereingaben, und wird als
    # eigenes Argument übergeben (keine Shell-Interpretation).
    def disk_usage(path)
      out, status = Open3.capture2('df', '-Pk', path.to_s)
      return nil unless status.success?

      fields = out.lines[1].to_s.split
      return nil if fields.size < 4

      total = fields[1].to_i * 1024
      used = fields[2].to_i * 1024
      free = fields[3].to_i * 1024
      return nil if total.zero?

      {
        total_bytes: total,
        used_bytes: used,
        free_bytes: free,
        # Ganze Prozent, bewusst ohne Dezimalstelle: Genau dieser Wert wird als
        # Tageswert mitgeschrieben und dient dem Vergleich in der Frühwarnung.
        # Eine Nachkommastelle in der Anzeige und ein gerundeter Wert im Vergleich
        # würden bei 89,6 Prozent unterschiedlich urteilen.
        used_percent: (used * 100.0 / total).round
      }
    rescue StandardError => e
      Rails.logger.error("SystemHealth#disk_usage failed: #{e.class}: #{e.message}")
      nil
    end

    def operations
      {
        version: SAISONMANAGER_VERSION,
        environment: Rails.env,
        pending_migrations: pending_migrations?,
        rails_root_path: Rails.root.to_s
      }
    end

    # `check_all_pending!` wirft, wenn etwas offen ist. Der Aufruf darf die Seite
    # nicht mitreißen, deshalb nil bei einem unerwarteten Fehler (dann steht auf
    # der Seite „unbekannt" statt einer falschen Beruhigung).
    def pending_migrations?
      ActiveRecord::Migration.check_all_pending!
      false
    rescue ActiveRecord::PendingMigrationError
      true
    rescue StandardError => e
      Rails.logger.error("SystemHealth#pending_migrations? failed: #{e.class}: #{e.message}")
      nil
    end

    def status_for_percent(percent)
      return 'unknown' if percent.nil?
      return 'critical' if percent >= CRITICAL_PERCENT
      return 'warning' if percent >= WARNING_PERCENT

      'ok'
    end

    # Derzeit hängt der Gesamtzustand allein an der Platte. Kommen weitere
    # Kennzahlen mit Ampel hinzu, wird hier der schlechteste Wert gebildet.
    def overall_status(disk = uploads_disk)
      disk[:status] || 'unknown'
    end

    def severity(status)
      case status
      when 'warning' then 1
      when 'critical' then 2
      else 0
      end
    end
  end
end
