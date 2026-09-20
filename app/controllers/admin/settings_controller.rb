module Admin
  class SettingsController < ApplicationController
    before_action :require_admin!, only: %i[create_season update_season]
    before_action :require_admin_or_rsk!, only: %i[seasons]

    def seasons
      render json: {
        current_season_id: Setting.current_season_id,
        seasons: Setting.seasons
      }
    end

    def create_season
      name = params[:name].to_s.strip
      return render json: { error: 'Name darf nicht leer sein' }, status: :unprocessable_entity if name.blank?

      setting = Setting.first
      next_id = (setting.seasons.keys.map(&:to_i).max || 0) + 1

      # min_league_id / min_team_id grenzen die neue Saison gegen alle bisherigen Liga-/Team-IDs ab.
      # Spätere Liga-/Team-Erstellungen erhalten höhere IDs und werden so der neuen Saison zugeordnet
      # (Setting.current_min_team / current_min_league filtern darauf).
      min_league_id = (League.maximum(:id) || 0) + 1
      min_team_id   = (Team.maximum(:id) || 0) + 1

      setting.seasons = setting.seasons.merge(
        next_id.to_s => { 'name' => name, 'min_league_id' => min_league_id, 'min_team_id' => min_team_id }
      )
      setting.save!

      render json: {
        id: next_id,
        name: name,
        current: false,
        min_league_id: min_league_id,
        min_team_id: min_team_id
      }, status: :created
    end

    # Der Saisonwechsel schließt zugleich die Spielberichte aller vergangenen
    # Saisons (PastSeasonReportCloser). Ein offen gebliebener Bericht bleibt
    # sonst dauerhaft bearbeitbar für jeden, der ihn ohnehin bearbeiten darf --
    # beim ausrichtenden Verein auch Jahre später noch. Der Wechsel ist der
    # Moment, an dem der Spielbetrieb der alten Saison endet.
    #
    # Der Abschluss läuft nach dem Speichern und außerhalb davon: Er ist eine
    # Folge des Wechsels, keine Bedingung für ihn. Scheitert er, steht die neue
    # Saison trotzdem, und die Antwort sagt es -- das Gegenteil (Wechsel
    # zurückgedreht, weil ein Altbestand-Spiel sich querstellt) wäre die
    # schlechtere Hälfte.
    def update_season
      new_id = params[:season_id].to_i
      setting = Setting.first
      unless setting.seasons.key?(new_id.to_s)
        return render json: { error: 'Unbekannte Saison-ID' }, status: :unprocessable_entity
      end

      systems = (setting.systems || {}).dup
      systems['1'] = (systems['1'] || {}).merge('current_season_id' => new_id)
      setting.systems = systems
      setting.save!

      render json: { current_season_id: new_id }.merge(closed_reports(new_id))
    end

    private

    # Idempotent, ein zweiter Wechsel findet nichts mehr. Der Zähler geht mit in
    # die Antwort, damit die Oberfläche sagen kann, was passiert ist -- ein
    # stiller Sammelabschluss über Tausende Spiele wäre das Letzte, was man an
    # dieser Stelle erwartet.
    def closed_reports(new_id)
      result = PastSeasonReportCloser.call(current_season_id: new_id)
      { closed_reports: result.games, closed_report_leagues: result.leagues }
    rescue StandardError => e
      Rails.logger.error(
        "Saisonwechsel auf #{new_id}: Sammelabschluss der Altberichte fehlgeschlagen: " \
        "#{e.class}: #{e.message}"
      )
      Sentry.capture_exception(e) if defined?(Sentry)
      { closed_reports_error: 'Die Spielberichte der Vorsaisons konnten nicht geschlossen werden.' }
    end

    def require_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def require_admin_or_rsk!
      ph = current_user.permission_hash
      # Ansetzer brauchen die Saisonliste für die Ansetzungs-/Verfügbarkeits-Ansichten
      # (deren Frontend ruft seasons beim Laden auf), daher hier ebenfalls erlaubt.
      return if ph[:admin].present? || ph[:rsk].present? || ph[:ansetzer].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
