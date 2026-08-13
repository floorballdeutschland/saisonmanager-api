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
        previous = previous_status(upto: date)
        warning_due = notify && worsened?(previous, current)

        # Erst versenden, dann den Tageswert schreiben. Der Tageswert IST der
        # Merker dafür, dass gewarnt wurde: Stünde er schon in der Datenbank,
        # während die Mail verloren geht, sähe der nächste Lauf denselben Zustand,
        # keine Verschlechterung, und würde nie nachwarnen. Bei „critical" wäre
        # das der schlimmste Fall, darüber gibt es keine Stufe mehr, die noch
        # eskalieren könnte.
        notified = warning_due ? deliver_warning(disk) : false

        # Bei verlorener Mail den Tageswert bewusst NICHT schreiben, damit der
        # nächste Lauf dieselbe Verschlechterung wieder sieht und es nachholt.
        # Eine Dublette bei fehlgeschlagenem Schreiben ist die harmlose Seite.
        if record && disk[:used_percent].present? && (!warning_due || notified)
          DailyMetric.set!(DISK_METRIC_KEY, disk[:used_percent], date)
        end

        {
          previous_status: previous,
          status: current,
          used_percent: disk[:used_percent],
          notified: notified,
          delivery_failed: warning_due && !notified
        }
      end

      # Zustand der jüngsten Messung bis einschließlich des angegebenen Tages.
      #
      # Bewusst nicht „gestern": Läuft der Job einen Tag nicht, soll der
      # davorliegende Wert gelten und die Lücke nicht als Verbesserung durchgehen
      # und erneut warnen. Und bewusst einschließend: Ein zweiter Lauf am selben
      # Tag findet so den bereits geschriebenen Wert und schickt dieselbe Mail
      # nicht noch einmal. Der Rake-Kopf nennt den Aufruf von Hand, dieser Fall
      # ist also erreichbar.
      def previous_status(upto: Date.current)
        percent = DailyMetric
                  .where(metric_key: DISK_METRIC_KEY)
                  .where(date: ..upto)
                  .order(date: :desc)
                  .limit(1)
                  .pick(:count)

        SystemHealth.status_for_percent(percent)
      end

      # true bei erfolgreichem Versand. Der Fehler wird geloggt statt geworfen,
      # nach dem Muster aus RefereeFeedbackNotifier#deliver: `deliver_now` schlägt
      # in Produktion sofort auf (raise_delivery_errors ist dort aktiv) und würde
      # den täglichen Lauf sonst mitten im Durchgang abbrechen.
      def deliver_warning(disk)
        SystemHealthMailer.threshold_warning(disk).deliver_now
        true
      rescue StandardError => e
        Rails.logger.error("SystemHealth-Warnmail fehlgeschlagen: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        false
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
