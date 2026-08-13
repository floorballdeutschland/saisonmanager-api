class SettingsController < ApplicationController
  skip_before_action :authenticate_user
  before_action :authenticate_public_request

  # GET /settings
  def index
    @settings = Setting.all

    render json: @settings
  end

  def init
    result = Rails.cache.fetch('settings/init', expires_in: 30.minutes) do
      {
        seasons: Setting.seasons,
        current_season_id: Setting.current_season_id,
        game_operations: GameOperation.includes(state_association: { logo_attachment: :blob }).map(&:short_hash),
        state_associations: StateAssociation.with_attached_logo.with_attached_banner.order(:name).map(&:short_hash),
        # Redaktionell gepflegte Links auf externe Informationsblätter. Hier
        # mitgeliefert, weil das Frontend sie auch außerhalb der Admin-Rollen
        # braucht (Vereinsmanager im Lizenzantrag) und init ohnehin einmal je
        # Seitenaufbau geladen wird. Nur Keys mit gepflegter URL.
        info_links: Setting::INFO_LINK_KEYS.index_with { |key| Setting.info_link_url(key) }.compact
      }
    end

    # Erster Request jedes Seitenaufbaus (Verbände + Saisons) – nutzerunabhängig,
    # ändert sich praktisch nur bei Saisonwechsel/Verbandspflege.
    expires_in 60.seconds, public: true
    render json: result
  end
end
