module Admin
  # Betriebszustand des Servers für die Admin-Seite „System". Reine Lesesicht,
  # die Kennzahlen selbst liegen in SystemHealth.
  class SystemHealthController < ApplicationController
    before_action :authorize_admin!

    # GET /api/v2/admin/system_health
    def show
      render json: SystemHealth.report
    rescue StandardError => e
      # Die Seite ist ein Diagnosewerkzeug: Ein Fehler beim Erheben einer
      # einzelnen Kennzahl wird in SystemHealth abgefangen. Bleibt trotzdem etwas
      # übrig, ist die Antwort ein sauberer Fehler statt einer halben Ausgabe.
      Rails.logger.error("SystemHealthController#show failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e)
      render json: { error: 'Systemkennzahlen konnten nicht erhoben werden.' }, status: :service_unavailable
    end

    # GET /api/v2/admin/system_health/summary
    #
    # Nur der Zustand der Platte, für den Hinweisstreifen im Frontend. Absichtlich
    # getrennt von #show: Der Streifen wird bei jedem App-Start eines Admins
    # geladen und soll dafür nicht die Aufschlüsselungen und Tabellengrößen
    # mitberechnen.
    def summary
      disk = SystemHealth.uploads_disk

      render json: {
        status: disk[:status],
        used_percent: disk[:used_percent],
        free_bytes: disk[:free_bytes]
      }
    rescue StandardError => e
      Rails.logger.error("SystemHealthController#summary failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e)
      render json: { error: 'Systemkennzahlen konnten nicht erhoben werden.' }, status: :service_unavailable
    end

    private

    def authorize_admin!
      return if current_user.permission_hash[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
