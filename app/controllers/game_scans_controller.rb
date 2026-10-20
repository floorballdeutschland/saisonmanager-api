# Papierspielberichtsbogen zu einem Spiel: hochladen, ansehen, entfernen.
class GameScansController < ApplicationController
  include SecretaryTokenAuthenticatable

  # Lesen und Hochladen stehen derselben Runde offen wie der Spielbericht selbst,
  # also auch dem Spielsekretariat per Einmal-Link, das ohne Benutzerkonto
  # arbeitet. `destroy` bleibt an der Anmeldung, siehe check_permission.
  skip_before_action :authenticate_user, only: %i[show create]
  before_action :authenticate_with_secretary_token_or_user, only: %i[show create]
  before_action :set_game
  before_action :check_permission

  def show
    scan = @game.game_scan&.then { |s| s.expires_at > Time.current ? s : nil }

    if scan&.scan_file&.attached?
      render json: scan_json(scan)
    else
      render json: nil
    end
  end

  def create
    return render json: { errors: ['Datei fehlt'] }, status: :unprocessable_entity if params[:file].blank?

    # Vor dem Anlegen lesen: `GameScan.new(game: @game)` setzt über die
    # Gegenseite `@game.game_scan` auf den neuen, noch ungespeicherten Scan.
    existing = @game.game_scan

    scan = GameScan.new(
      game: @game,
      # Ohne Anmeldung (Sekretariats-Link) wird der Aussteller des Links
      # eingetragen, wie überall auf dem Token-Pfad. Siehe
      # SecretaryTokenAuthenticatable#secretary_or_current_user_id.
      uploaded_by_id: secretary_or_current_user_id,
      expires_at: Time.current + 12.months
    )
    scan.scan_file.attach(params[:file])

    if replace_scan(existing, scan)
      render json: scan_json(scan), status: :created
    else
      render json: { errors: scan.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # Löschen ist Kontrolle, nicht Berichtsführung: bewusst nur Admin und die SBK
  # des Spielbetriebs, nicht die weitere Runde aus check_permission. Ein
  # Sekretariats-Link kommt hier gar nicht erst an, `authenticate_user` gilt für
  # diese Action unverändert.
  def destroy
    ph = current_user.permission_hash
    game_operation_id = @game.game_day.league.game_operation_id.to_i
    gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)
    unless gos.include?(0) || gos.include?(game_operation_id)
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    scan = @game.game_scan
    if scan
      scan.scan_file.purge
      scan.destroy
      render json: { success: true }
    else
      render json: { message: 'Kein Scan vorhanden.' }, status: :not_found
    end
  end

  private

  # Der vorhandene Scan geht erst, wenn der neue gültig ist. Vorher wurde er
  # gelöscht, bevor die neue Datei geprüft war: Ein abgewiesenes Foto nahm den
  # gültigen Scan mit, und das Spiel stand ohne Bogen da.
  #
  # Beides in einer Transaktion, weil `game_id` eindeutig ist und der neue
  # Datensatz erst nach dem Löschen des alten gespeichert werden kann. Scheitert
  # die Prüfung, rollt das Löschen mit zurück. Die Datei des alten Scans
  # entfernt ActiveStorage erst nach dem Commit (`purge_later` am
  # has_one_attached), ein Rollback lässt sie also unberührt.
  def replace_scan(existing, scan)
    return false unless new_scan_valid?(scan)

    GameScan.transaction do
      existing&.destroy!
      scan.save || raise(ActiveRecord::Rollback)
    end
  end

  # Die Prüfung ohne die Eindeutigkeit von `game_id`: Die schlägt an, solange
  # der alte Scan noch steht, und sagt über die Datei nichts.
  def new_scan_valid?(scan)
    return true if scan.valid?

    scan.errors.delete(:game_id, :taken)
    scan.errors.empty?
  end

  def set_game
    @game = Game.find(params[:game_id])
  end

  # Derselbe Maßstab wie der Spielbericht (GamesController#can_edit_game?): Wer
  # den Bericht führen darf, lädt auch den Papierbogen dazu hoch. Vorher waren es
  # nur Admin, die SBK des Spielbetriebs und der Vereinsmanager des Ausrichters –
  # nicht die Teammanager der beteiligten Mannschaften, nicht die
  # Vereinsmanager der beteiligten Vereine und nicht das Spielsekretariat per
  # Link, obwohl die Oberfläche allen dreien das Feld einblendet.
  #
  # Das traf nicht nur den Upload: `show` hängt an derselben Prüfung, die
  # Berichtsansicht ruft ihn bei Scan-Pflicht beim Öffnen ab, und der
  # ErrorInterceptor wirft bei 403 auf die Startseite. Wer den Bogen hochladen
  # sollte, flog also aus der Ansicht, bevor er etwas tun konnte.
  #
  # Rolle und Token sind additiv, keiner der beiden Wege sticht den anderen
  # (#428).
  def check_permission
    return if secretary_token_permits_game?(@game)
    return if current_user && @game.can_edit_lineup?(current_user)

    render json: { message: 'Keine Berechtigung.' }, status: :forbidden
  end

  def scan_json(scan)
    {
      filename: scan.scan_file.filename.to_s,
      content_type: scan.scan_file.content_type,
      byte_size: scan.scan_file.byte_size,
      uploaded_at: scan.created_at,
      uploaded_by_name: scan.uploaded_by&.fullname,
      expires_at: scan.expires_at.to_date,
      url: rails_blob_url(scan.scan_file, disposition: 'inline')
    }
  end
end
