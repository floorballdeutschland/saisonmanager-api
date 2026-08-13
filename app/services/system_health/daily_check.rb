module SystemHealth
  # Der tägliche Frühwarn-Lauf zum Speicherplatz (siehe lib/tasks/system_health.rake).
  #
  # Getrennt von SystemHealth, weil hier nicht gemessen, sondern entschieden wird:
  # Wann ist eine Meldung fällig? Die Regel lautet „nur bei einer Verschlechterung
  # gegenüber der letzten vorliegenden Messung". Damit kommt beim Überschreiten
  # einer Schwelle genau eine Mail, bei gleichbleibender Belegung keine weitere und
  # bei einer weiteren Verschlechterung wieder eine.
  #
  # Einen eigenen Merker braucht das nicht: Der Lauf schreibt die Belegung als
  # Tageswert mit (DailyMetric, Kennzahl DISK_METRIC_KEY), und genau dieser Wert
  # ist der Vergleichsmaßstab des nächsten Laufs. Nebeneffekt ist ein echter
  # Verlauf für die Admin-Seite.
  module DailyCheck
    class << self
      def run!(notify: true, record: true, date: Date.current)
        disk = SystemHealth.uploads_disk
        current = disk[:status]
        previous = previous_status(before: date)

        DailyMetric.set!(DISK_METRIC_KEY, disk[:used_percent], date) if record && disk[:used_percent].present?

        notified = notify && worsened?(previous, current)
        SystemHealthMailer.threshold_warning(disk).deliver_now if notified

        { previous_status: previous, status: current, used_percent: disk[:used_percent], notified: notified }
      end

      # Zustand der jüngsten Messung vor dem angegebenen Tag. Bewusst nicht „gestern":
      # Läuft der Job einen Tag nicht, soll der davorliegende Wert gelten und die
      # Lücke nicht als Verbesserung durchgehen und erneut warnen.
      def previous_status(before: Date.current)
        percent = DailyMetric
                  .where(metric_key: DISK_METRIC_KEY)
                  .where(date: ...before)
                  .order(date: :desc)
                  .limit(1)
                  .pick(:count)

        SystemHealth.status_for_percent(percent)
      end

      # „ok" → „warning" ist eine Verschlechterung, „warning" → „ok" nicht. „unknown"
      # ist keine: Ein fehlgeschlagenes `df` darf keine Mail auslösen, sonst warnt
      # der Job vor seinem eigenen Messfehler.
      def worsened?(previous, current)
        return false unless STATUSES.include?(current)
        return false if %w[ok unknown].include?(current)

        SystemHealth.severity(current) > SystemHealth.severity(previous)
      end
    end
  end
end
