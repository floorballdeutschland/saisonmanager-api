# Ausgabe und Rücknahme des Overlay-Zugangs für einen Spieltag. Aufgerufen aus
# dem Spielbericht, wo der Streamer ohnehin den Stream-Link hinterlegt.
class GameDayOverlayLinksController < ApplicationController
  include GameDayLinkAuthorization

  before_action :authenticate_user
  before_action :load_game_day
  before_action :authorize_vm_or_tm!

  # POST /api/v2/user/game_days/:game_day_id/overlay_link
  def create
    link, raw_token = GameDayOverlayLink.generate!(game_day: @game_day, created_by: current_user)

    render json: link_urls(raw_token).merge(
      expires_at: link.expires_at.iso8601,
      created_by: current_user.fullname,
      game_day_id: @game_day.id
    ), status: :created
  end

  # GET /api/v2/user/game_days/:game_day_id/overlay_link
  #
  # Nur der Zustand des Links, nie das Token: Der Klartext existiert einmalig in
  # der Antwort auf #create, gespeichert ist bloß sein Digest.
  def show
    link = GameDayOverlayLink.active.find_by(game_day: @game_day)

    if link
      render json: {
        active: true,
        expires_at: link.expires_at.iso8601,
        created_by: link.created_by&.fullname
      }
    else
      render json: { active: false }
    end
  end

  # DELETE /api/v2/user/game_days/:game_day_id/overlay_link
  #
  # Ausdrücklicher Widerruf, etwa wenn ein Link im Vereinschat gelandet ist.
  # Ohne diesen Weg bliebe nur, einen neuen zu erzeugen und den alten dadurch zu
  # verdrängen; das gibt aber wieder ein gültiges Token heraus.
  def destroy
    GameDayOverlayLink.where(game_day: @game_day).destroy_all

    render json: { active: false }
  end

  private

  def link_urls(raw_token)
    base = FrontendUrl.base

    {
      token: raw_token,
      # Die eine Bühne für Anzeigetafel und Bauchbinden, als Browser-Quelle in
      # 1920x1080. Die Endung .html ist nötig: nginx liefert nur bei exakter
      # Übereinstimmung die Datei aus, sonst landet der Aufruf im Angular-Router.
      overlay_url: "#{base}/overlay/index.html?token=#{raw_token}",
      # Als eigenes Dock in OBS („Ansicht > Docks > Benutzerdefiniertes
      # Browser-Dock").
      dock_url: "#{base}/overlay/dock.html?token=#{raw_token}"
    }
  end
end
