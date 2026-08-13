module SystemHealth
  # Was den Platz belegt: Uploads nach Art, die größten Einzeldateien, die Größe
  # der Datenbank und das Wachstum der letzten Monate.
  #
  # Getrennt von SystemHealth, weil hier alles aus der Datenbank kommt, während
  # dort der Datenträger gemessen wird. Die Prognose braucht beides und wird
  # deshalb mit dem Platten-Wert aufgerufen.
  module Inventory
    class << self
      # Maßgeblich für die Art eines Uploads ist der Anhang-Name (license_document,
      # logo, banner …) zusammen mit dem Modell, weil dieselbe Bezeichnung an
      # mehreren Modellen hängt.
      def uploads
        {
          blob_count: ActiveStorage::Blob.count,
          total_bytes: ActiveStorage::Blob.sum(:byte_size).to_i,
          # Verwaiste Dateien (kein Anhang mehr) belegen weiter Platz und tauchen in
          # keiner Aufschlüsselung auf, deshalb separat ausgewiesen.
          unattached_count: ActiveStorage::Blob.where.missing(:attachments).count,
          by_kind: by_kind,
          largest: largest_blobs
        }
      end

      def by_kind
        rows = ActiveStorage::Attachment
               .joins(:blob)
               .group(:record_type, :name)
               .pluck(Arel.sql('active_storage_attachments.record_type'),
                      Arel.sql('active_storage_attachments.name'),
                      Arel.sql('COUNT(*)'),
                      Arel.sql('COALESCE(SUM(active_storage_blobs.byte_size), 0)'))

        rows
          .map { |record_type, name, count, bytes| { record_type:, name:, count:, total_bytes: bytes.to_i } }
          .sort_by { |row| -row[:total_bytes] }
      end

      def largest_blobs(limit = 10)
        rows = ActiveStorage::Blob
               .order(byte_size: :desc)
               .limit(limit)
               .pluck(:filename, :content_type, :byte_size, :created_at)

        rows.map do |filename, content_type, byte_size, created_at|
          { filename:, content_type:, byte_size:, created_at: created_at&.iso8601 }
        end
      end

      def database
        size = ActiveRecord::Base.connection.select_value(
          'SELECT pg_database_size(current_database())'
        ).to_i

        { size_bytes: size, largest_tables: largest_tables }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.error("SystemHealth::Inventory.database failed: #{e.class}: #{e.message}")
        { size_bytes: nil, largest_tables: [] }
      end

      # Größe inklusive Indizes und TOAST, damit ein unerwarteter Ausreißer
      # sichtbar wird und nicht hinter der reinen Zeilengröße verschwindet.
      def largest_tables(limit = 10)
        rows = ActiveRecord::Base.connection.select_rows(<<~SQL.squish)
          SELECT relname, pg_total_relation_size(C.oid) AS total_bytes
          FROM pg_class C
          JOIN pg_namespace N ON N.oid = C.relnamespace
          WHERE N.nspname = 'public' AND C.relkind = 'r'
          ORDER BY total_bytes DESC
          LIMIT #{limit.to_i}
        SQL

        rows.map { |name, bytes| { name: name, total_bytes: bytes.to_i } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.error("SystemHealth::Inventory.largest_tables failed: #{e.class}: #{e.message}")
        []
      end

      # Wachstum der Uploads je Monat plus die daraus abgeleitete Restlaufzeit. Die
      # Prognose ist absichtlich grob: Sie soll die Größenordnung liefern („noch
      # Jahre" oder „noch Monate"), nicht ein Datum.
      def growth(free_bytes)
        months = monthly_upload_bytes
        recent = months.last(FORECAST_MONTHS)
        avg = recent.any? ? (recent.sum { |m| m[:total_bytes] } / recent.size.to_f).round : 0

        {
          months: months,
          avg_bytes_per_month: avg,
          months_until_full: months_until_full(free_bytes, avg)
        }
      end

      def monthly_upload_bytes
        start = Date.current.beginning_of_month << (HISTORY_MONTHS - 1)
        month_expr = Arel.sql("TO_CHAR(created_at, 'YYYY-MM')")

        grouped = ActiveStorage::Blob
                  .where(created_at: start..)
                  .group(month_expr)
                  .pluck(month_expr, Arel.sql('COUNT(*)'), Arel.sql('COALESCE(SUM(byte_size), 0)'))
                  .to_h { |month, count, bytes| [month, { count: count, total_bytes: bytes.to_i }] }

        (0...HISTORY_MONTHS).map do |i|
          key = (start >> i).strftime('%Y-%m')
          row = grouped[key] || { count: 0, total_bytes: 0 }
          { month: key, count: row[:count], total_bytes: row[:total_bytes] }
        end
      end

      # nil heißt „keine Aussage möglich": ohne Platten-Wert oder ohne Wachstum gibt
      # es keine sinnvolle Restlaufzeit. Ein Wachstum von 0 ist auf einem frischen
      # System der Normalfall und darf keine Division durch Null auslösen.
      def months_until_full(free_bytes, avg_bytes_per_month)
        return nil if free_bytes.nil? || avg_bytes_per_month.to_i <= 0

        (free_bytes / avg_bytes_per_month.to_f).floor
      end
    end
  end
end
