# frozen_string_literal: true

# Kalibrierung und Szenenauswahl eines Tablet-Spiels (fe#560), siehe
# HighlightEditor.
#
# Drei Wege:
#
# - POST games/:id/highlight_request  { email? }
#   Beim Beenden des Tabletmodus: "Schickt mir den Link, sobald das Video da
#   ist." Wer das Spiel im Spielbericht bearbeiten darf, auch per
#   Sekretariats-Link und auch nach dem Abschluss (wie die Rückmeldung zur
#   Beta). Ohne Adresse geht die Mail an das angemeldete Konto.
# - GET/PUT highlight_editor?token=…
#   Der Mail-Link. Der Token steht im Query-String wie beim Overlay, damit
#   Rack::Attack ihn ohne den Body zu lesen zählen kann.
# - GET/PUT games/:id/highlight_editor
#   Admin und SBK des Spielbetriebs mit Sitzung, auch nach Ablauf des Links.
class HighlightEditorController < ApplicationController
  include SecretaryTokenAuthenticatable
  include GameReportPermissions

  skip_before_action :authenticate_user, only: %i[request_link show_by_token update_by_token]
  before_action :authenticate_with_secretary_token_or_user, only: :request_link
  before_action :set_game, only: %i[request_link show update]
  before_action :require_sbk, only: %i[show update]
  before_action :set_request_by_token, only: %i[show_by_token update_by_token]

  # POST games/:id/highlight_request
  def request_link
    return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless can_edit_game?(@game)
    unless @game.tablet_capture?
      return render json: { message: 'Das Spiel wurde nicht im Tabletmodus erfasst.' }, status: :unprocessable_entity
    end

    email = params[:email].to_s.strip.presence
    anfrage = TabletHighlightRequest.new(game: @game, email: email, user: email ? nil : current_user)
    unless anfrage.valid?
      meldung = email ? 'Die E-Mail-Adresse ist ungültig.' : 'Bitte gib eine E-Mail-Adresse an.'
      return render json: { message: meldung }, status: :unprocessable_entity
    end

    # Dieselbe Person zweimal: einmal reicht.
    offen = TabletHighlightRequest.pending.where(game: @game)
    doppelt = email ? offen.where('lower(email) = ?', email.downcase) : offen.where(user_id: current_user.id, email: nil)
    return head :accepted if doppelt.exists?

    if offen.count >= TabletHighlightRequest::MAX_PENDING_PER_GAME
      return render json: { message: 'Für dieses Spiel sind schon genug Anfragen offen.' },
                    status: :unprocessable_entity
    end

    anfrage.save!
    head :accepted
  end

  # GET highlight_editor?token=…
  def show_by_token
    render json: HighlightEditor.new(@request.game).as_json.merge(expires_at: @request.expires_at.utc.iso8601)
  end

  # PUT highlight_editor?token=…  { offset_seconds?, scenes? }
  def update_by_token
    speichern(@request.game, user: nil) do |editor|
      editor.as_json.merge(expires_at: @request.expires_at.utc.iso8601)
    end
  end

  # GET games/:id/highlight_editor
  def show
    render json: HighlightEditor.new(@game).as_json
  end

  # PUT games/:id/highlight_editor
  def update
    speichern(@game, user: current_user, &:as_json)
  end

  private

  def speichern(game, user:)
    editor = HighlightEditor.new(game)
    editor.update!(editor_params, user: user)
    render json: yield(editor)
  rescue HighlightEditor::Invalid => e
    render json: { message: e.message }, status: :unprocessable_entity
  end

  def editor_params
    request.request_parameters.with_indifferent_access.slice(:offset_seconds, :scenes)
  end

  def set_game
    @game = Game.find(params[:id])
  end

  def require_sbk
    render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless admin_or_scoped_sbk?(@game)
  end

  # Unbekannt 404, abgelaufen 410: Die Seite soll "Link abgelaufen" sagen
  # können statt "gibt es nicht".
  def set_request_by_token
    @request = TabletHighlightRequest.find_by_token(request.query_parameters['token'])
    return render json: { message: 'Link nicht gefunden.' }, status: :not_found if @request.nil?

    return unless @request.expired?

    render json: { message: 'Der Link ist abgelaufen. Die SBK kann die Highlights weiter bearbeiten.' },
           status: :gone
  end
end
