# frozen_string_literal: true

# Schüsse des Tabletmodus (api#816, fe#344).
#
# Schreiben mit denselben Rechten wie die Ereignisse (GamesController#add_event):
# wer den Spielbericht bearbeiten darf, inklusive Sekretariats-Link; nach dem
# Abschluss nur noch Admin und SBK des Spielbetriebs (GameReportPermissions).
#
# Jede Schreibantwort liefert ALLE Schüsse des Spiels. Das Tablet puffert bei
# Verbindungsabbruch und gleicht danach seinen Stand mit dieser Liste ab.
#
# `detailed_stats` ist öffentlich (API-Key oder Sitzung) und nur für Spiele,
# die im Tabletmodus erfasst wurden; sonst 404, damit die Spielseite den Reiter
# gar nicht erst zeigt.
class GameShotsController < ApplicationController
  include SecretaryTokenAuthenticatable
  include GameReportPermissions

  EDIT_ACTIONS = %i[index create update destroy link tablet_capture].freeze

  skip_before_action :authenticate_user
  before_action :authenticate_with_secretary_token_or_user, only: EDIT_ACTIONS
  before_action :authenticate_public_request, only: %i[detailed_stats highlights]
  before_action :set_game
  before_action :require_read, only: %i[index]
  before_action :require_write, only: %i[create update destroy link tablet_capture]
  before_action :set_shot, only: %i[update destroy link]

  # GET games/:id/shots
  def index
    render_shots
  end

  # POST games/:id/shots  { shots: [ShotInput] }
  #
  # Idempotent über `client_uuid`: Ein schon bekannter Schuss wird aktualisiert,
  # nicht doppelt angelegt. Alles oder nichts, damit das Tablet nach einem
  # Fehler seinen Puffer unverändert erneut schicken kann.
  def create
    eingaben = params.require(:shots)
    unless eingaben.is_a?(Array) && eingaben.size <= 500
      return render json: { message: 'shots muss eine Liste mit höchstens 500 Einträgen sein.' },
                    status: :unprocessable_entity
    end

    unless eingaben.all? { |eingabe| eingabe.is_a?(ActionController::Parameters) || eingabe.is_a?(Hash) }
      return render json: { message: 'Jeder Eintrag in shots muss ein Objekt sein.' }, status: :unprocessable_entity
    end

    fehler, gespeichert = schuesse_speichern(eingaben)
    return render json: { message: fehler }, status: :unprocessable_entity if fehler

    mark_tablet_capture! if eingaben.any?
    GameShotLinker.link_new_shots(@game, gespeichert)
    GameShotStats.flush!(@game)
    render_shots
  end

  # PATCH games/:id/shots/:client_uuid
  def update
    @shot.assign_attributes(shot_attributes(params).except('client_uuid'))
    if @shot.event_id && @shot.team_changed? && (fehler = team_mismatch(@shot.event_id))
      return render json: { message: fehler }, status: :unprocessable_entity
    end

    unless @shot.save
      return render json: { message: @shot.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    GameShotStats.flush!(@game)
    render_shots
  end

  # DELETE games/:id/shots/:client_uuid
  def destroy
    @shot.destroy!
    GameShotStats.flush!(@game)
    render_shots
  end

  # POST games/:id/shots/:client_uuid/link  { event_id: number|null }
  #
  # Von Hand verknüpfen oder lösen. Ein Tor trägt höchstens einen Schuss: Hing
  # schon ein anderer daran, wird er gelöst.
  def link
    event_id = params[:event_id].presence&.to_i
    if event_id && (fehler = link_error(event_id))
      return render json: { message: fehler }, status: :unprocessable_entity
    end

    GameShot.transaction do
      @game.game_shots.where(event_id: event_id).where.not(id: @shot.id).update_all(event_id: nil) if event_id
      @shot.update!(event_id: event_id)
    end
    GameShotStats.flush!(@game)
    render_shots
  end

  # PUT games/:id/tablet_capture  { complete: boolean }
  #
  # "Schüsse vollständig erfasst?" beim Abschluss. Unvollständige Spiele
  # bleiben aus späteren Saisonstatistiken heraus; die Spielseite zeigt einen
  # Hinweis.
  def tablet_capture
    unless %w[true false].include?(params[:complete].to_s)
      return render json: { message: 'complete muss true oder false sein.' }, status: :unprocessable_entity
    end

    @game.update_columns(tablet_shots_complete: params[:complete].to_s == 'true', updated_at: Time.current)
    GameShotStats.flush!(@game)
    render json: { tablet_shots_complete: @game.tablet_shots_complete }
  end

  # GET games/:id/detailed_stats (öffentlich)
  def detailed_stats
    unless @game.tablet_capture?
      return render json: { message: 'Keine ausführliche Statistik für dieses Spiel.' }, status: :not_found
    end

    delayed = delay_live_data? && !@game.ended?
    cutoff = delayed ? Time.current - LIVE_DATA_DELAY : nil
    render json: GameShotStats.cached(@game, delayed: delayed, cutoff: cutoff)
  end

  # GET games/:id/highlights (öffentlich, fe#555)
  #
  # Szenen der Tore mit verknüpftem Schuss in der Stream-Aufzeichnung. Fragt
  # YouTube nicht, sondern liest Start und Länge, die der Wächter an
  # `stream_broadcasts` gespeichert hat (StreamChapters).
  def highlights
    unless @game.tablet_capture?
      return render json: { message: 'Keine Highlights für dieses Spiel.' }, status: :not_found
    end

    delayed = delay_live_data? && !@game.ended?
    cutoff = delayed ? Time.current - LIVE_DATA_DELAY : nil
    render json: GameHighlights.cached(@game, delayed: delayed, cutoff: cutoff)
  end

  private

  def set_game
    @game = Game.find(params[:id])
  end

  def set_shot
    @shot = @game.game_shots.find_by(client_uuid: params[:client_uuid])
    render json: { message: 'Schuss nicht gefunden.' }, status: :not_found if @shot.nil?
  end

  # Lesen darf, wer schreiben dürfte, auch nach dem Abschluss: Admin und SBK
  # korrigieren dann noch, und wer vorher erfasst hat, soll seinen Stand sehen.
  def require_read
    render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless can_edit_game?(@game)
  end

  def require_write
    render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless can_write_events?(@game)
  end

  def shot_attributes(quelle)
    quelle = quelle.to_unsafe_h if quelle.respond_to?(:to_unsafe_h)
    quelle.to_h.stringify_keys.slice(*GameShot::INPUT_FIELDS)
  end

  def link_error(event_id)
    return 'Nur ein Tor-Schuss kann mit einem Tor verknüpft werden.' unless @shot.result == 'goal'
    return 'Tor nicht gefunden.' if goal_event(event_id).nil?

    team_mismatch(event_id)
  end

  def team_mismatch(event_id)
    tor = goal_event(event_id)
    return nil if tor.nil? || tor[:event_team].to_s == @shot.team

    'Schuss und Tor gehören zu verschiedenen Teams.'
  end

  def goal_event(event_id)
    @goal_events ||= @game.formatted_events.select { |event| event[:event_type] == :goal }
    @goal_events.find { |event| event[:event_id].to_i == event_id.to_i }
  end

  # Ein Stapel in einer Transaktion. Schicken zwei Geräte (oder ein Gerät nach
  # einem Abbruch doppelt) gleichzeitig dieselbe client_uuid, verliert einer
  # das Rennen um den eindeutigen Index; dann wird der Stapel einmal
  # wiederholt und trifft den inzwischen vorhandenen Schuss als Aktualisierung.
  def schuesse_speichern(eingaben, wiederholt: false)
    fehler = nil
    gespeichert = []
    GameShot.transaction do
      eingaben.each do |eingabe|
        fehler = schuss_speichern(shot_attributes(eingabe), gespeichert)
        raise ActiveRecord::Rollback if fehler
      end
    end
    [fehler, fehler ? [] : gespeichert]
  rescue ActiveRecord::RecordNotUnique
    raise if wiederholt

    schuesse_speichern(eingaben, wiederholt: true)
  end

  def schuss_speichern(attrs, gespeichert)
    shot = GameShot.find_or_initialize_by(client_uuid: attrs['client_uuid'].to_s)
    return "Schuss #{attrs['client_uuid']} gehört zu einem anderen Spiel." if shot.persisted? && shot.game_id != @game.id

    shot.game = @game
    shot.created_by ||= secretary_or_current_user_id
    shot.assign_attributes(attrs)
    return "Schuss #{attrs['client_uuid']}: #{shot.errors.full_messages.join(', ')}" unless shot.save

    gespeichert << shot
    nil
  end

  # Gesetzt beim ersten Schuss. `update_columns` mit `updated_at`, damit der
  # Cache der Spielseite (Schlüssel mit `updated_at`) sofort umschlägt, ohne
  # die Callbacks und Validierungen des Spiels durchzulaufen: Ein Altdatensatz
  # mit einer gerissenen Validierung soll das Erfassen nicht verhindern.
  def mark_tablet_capture!
    return if @game.tablet_capture?

    @game.update_columns(tablet_capture_at: Time.current, updated_at: Time.current)
  end

  def render_shots
    render json: { shots: @game.game_shots.order(:tapped_at, :id).map(&:as_api_json) }
  end
end
