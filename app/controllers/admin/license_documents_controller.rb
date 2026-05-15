module Admin
  class LicenseDocumentsController < ApplicationController
    before_action :set_player
    before_action :check_read_permission, only: %i[index show]
    before_action :check_write_permission, only: %i[create destroy]

    def index
      docs = @player.license_documents.includes(file_attachment: :blob).where(license_id: params[:license_id])
      render json: docs.map { |d| document_json(d) }
    end

    def show
      doc = @player.license_documents.find(params[:id])
      redirect_to rails_blob_url(doc.file, disposition: 'inline'), allow_other_host: true
    end

    def create
      return render json: { errors: ['Datei fehlt'] }, status: :unprocessable_entity if params[:file].blank?
      return render json: { errors: ['Dokumenttyp fehlt'] }, status: :unprocessable_entity if
        params[:document_type].blank?

      doc = LicenseDocument.new(
        player: @player,
        license_id: params[:license_id],
        document_type: params[:document_type],
        uploaded_by: current_user
      )
      doc.file.attach(params[:file])

      unless doc.valid?
        return render json: { errors: doc.errors.full_messages }, status: :unprocessable_entity
      end

      existing = @player.license_documents.find_by(license_id: params[:license_id], document_type: params[:document_type])
      ActiveRecord::Base.transaction do
        existing&.destroy
        doc.save!
      end

      render json: document_json(doc), status: :created
    end

    def destroy
      doc = @player.license_documents.find(params[:id])
      doc.file.purge
      doc.destroy
      render json: { success: true }
    end

    private

    def set_player
      @player = Player.find(params[:player_id])
    end

    def check_read_permission
      return if admin_or_sbk_for_player?
      return if vm_for_player?
      return if tm_for_player?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    def check_write_permission
      return if admin_or_sbk_for_player?
      return if vm_for_player?
      return if tm_for_player?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    def admin_or_sbk_for_player?
      ph = current_user.permission_hash
      return true if ph[:admin].present?

      if ph[:sbk].present?
        player_go_ids = player_game_operation_ids
        return true if ph[:sbk].include?(0)
        return true if (ph[:sbk] & player_go_ids).present?
      end

      false
    end

    def tm_for_player?
      ph = current_user.permission_hash
      return false if ph[:tm].blank?

      player_team_ids = (@player.licenses || []).filter_map { |l| l['team_id']&.to_i }
      (ph[:tm] & player_team_ids).present?
    end

    def vm_for_player?
      ph = current_user.permission_hash
      return false unless ph[:vm].present?

      player_club_ids = (@player.clubs || []).filter_map { |c| c['club_id'].to_i if c['valid_until'].nil? }
      (ph[:vm] & player_club_ids).present?
    end

    def player_game_operation_ids
      club_ids = (@player.clubs || []).filter_map { |c| c['club_id'].to_i }
      Club.where(id: club_ids).flat_map do |club|
        club.game_operations_hash.map { |go| go['game_operation_id'].to_i }
      end.uniq
    end

    def document_json(doc)
      {
        id: doc.id,
        document_type: doc.document_type,
        filename: doc.file.filename.to_s,
        content_type: doc.file.content_type,
        byte_size: doc.file.byte_size,
        created_at: doc.created_at,
        url: rails_blob_url(doc.file, disposition: 'inline')
      }
    end
  end
end
