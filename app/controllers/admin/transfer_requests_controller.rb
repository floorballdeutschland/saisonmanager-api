module Admin
  class TransferRequestsController < ApplicationController
    before_action :authenticate_user
    before_action :authorize_transfer_access!
    skip_before_action :authenticate_user, only: %i[player_approve player_reject]
    skip_before_action :authorize_transfer_access!, only: %i[player_approve player_reject]

    def index
      ph = current_user.permission_hash
      requests = if ph[:admin].present?
        TransferRequest.all
      elsif ph[:sbk].present?
        club_ids = ph[:sbk].include?(0) ? Club.pluck(:id) : derive_club_ids_for_go(ph[:sbk])
        TransferRequest.where(former_club_id: club_ids)
      elsif ph[:vm].present?
        TransferRequest
          .for_requesting_club(ph[:vm])
          .or(TransferRequest.for_former_club(ph[:vm]))
      else
        TransferRequest.none
      end

      render json: requests.order(created_at: :desc).map(&:as_json)
    end

    def search_player
      ph = current_user.permission_hash
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden unless ph[:vm].present? || ph[:admin].present? || ph[:sbk].present?

      first_name = params[:first_name]&.strip
      last_name  = params[:last_name]&.strip
      birthdate  = params[:birthdate]&.strip

      if first_name.blank? || last_name.blank? || birthdate.blank?
        return render json: { error: 'Vorname, Nachname und Geburtsdatum sind erforderlich' }, status: :unprocessable_entity
      end

      player = Player.where(
        'LOWER(first_name) = ? AND LOWER(last_name) = ? AND birthdate = ?',
        first_name.downcase, last_name.downcase, birthdate
      ).first

      return render json: { player: nil } unless player

      requesting_club_id = params[:requesting_club_id].to_i
      if ph[:vm].present?
        unless ph[:vm].include?(requesting_club_id)
          return render json: { error: 'Nicht berechtigt fuer diesen Verein' }, status: :forbidden
        end
      end

      if requesting_club_id > 0
        home_club = player.clubs.find { |c| c['home_club'] == true && c['valid_until'].nil? }
        if home_club&.dig('club_id') == requesting_club_id
          return render json: { error: 'Spieler ist bereits in diesem Verein' }, status: :unprocessable_entity
        end
      end

      if TransferRequest.active.where(player_id: player.id).exists?
        return render json: { error: 'Fuer diesen Spieler ist bereits ein Transferantrag aktiv' }, status: :unprocessable_entity
      end

      render json: { player: player.search_hash }
    end

    def show
      tr = find_transfer_request
      return unless tr

      render json: tr.as_json
    end

    def create
      ph = current_user.permission_hash
      return render json: { error: 'Nicht berechtigt' }, status: :forbidden unless ph[:vm].present? || ph[:admin].present?

      player = Player.find_by(id: params[:player_id])
      return render json: { error: 'Spieler nicht gefunden' }, status: :not_found unless player

      requesting_club_id = params[:requesting_club_id].to_i
      if ph[:vm].present? && !ph[:vm].include?(requesting_club_id)
        return render json: { error: 'Nicht berechtigt fuer diesen Verein' }, status: :forbidden
      end

      requesting_club = Club.find_by(id: requesting_club_id)
      return render json: { error: 'Verein nicht gefunden' }, status: :not_found unless requesting_club

      if TransferRequest.active.where(player_id: player.id).exists?
        return render json: { error: 'Fuer diesen Spieler ist bereits ein Transferantrag aktiv' }, status: :unprocessable_entity
      end

      home_club_entry = player.clubs.find { |c| c['home_club'] == true && c['valid_until'].nil? }
      former_club_id = home_club_entry&.dig('club_id')
      return render json: { error: 'Spieler hat keinen aktiven Heimverein' }, status: :unprocessable_entity unless former_club_id

      if former_club_id == requesting_club_id
        return render json: { error: 'Spieler ist bereits in diesem Verein' }, status: :unprocessable_entity
      end

      former_club = Club.find_by(id: former_club_id)
      return render json: { error: 'Abgebender Verein nicht gefunden' }, status: :not_found unless former_club

      request_type = params[:request_type].to_s == 'release' ? 'release' : 'transfer'

      effective_date = nil
      if request_type == 'transfer' && params[:effective_date].present?
        begin
          effective_date = Date.parse(params[:effective_date].to_s)
          if effective_date < Date.today + 7
            return render json: { error: 'Wunschdatum muss mindestens 7 Tage in der Zukunft liegen' }, status: :unprocessable_entity
          end
        rescue ArgumentError
          return render json: { error: 'Ungültiges Datum' }, status: :unprocessable_entity
        end
      end

      tr = TransferRequest.new(
        player_id: player.id,
        requesting_club_id: requesting_club_id,
        former_club_id: former_club_id,
        status: 'pending_club',
        created_by: current_user.id,
        season_id: Setting.current_season_id,
        effective_date:,
        request_type:
      )

      if tr.save
        TransferRequestMailer.new_request_to_former_club(tr).deliver_later
        render json: tr.as_json, status: :created
      else
        render json: { errors: tr.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def approve_club
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'pending_club'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:vm]&.include?(tr.former_club_id)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      unless tr.player.email.present?
        return render json: {
          error: 'Der Spieler hat keine E-Mail-Adresse hinterlegt. Bitte zuerst die E-Mail-Adresse im Spielerprofil eintragen.'
        }, status: :unprocessable_entity
      end

      tr.update!(
        status: 'pending_player',
        approved_by_club_user_id: current_user.id,
        club_approved_at: Time.current
      )

      TransferRequestMailer.player_confirmation_request(tr).deliver_later

      render json: tr.as_json
    end

    def reject_club
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'pending_club'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:vm]&.include?(tr.former_club_id)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      reason = params[:rejection_reason]&.strip
      if reason.blank?
        return render json: { error: 'Begruendung ist erforderlich' }, status: :unprocessable_entity
      end

      tr.update!(
        status: 'rejected_by_club',
        rejected_by: current_user.id,
        rejected_at: Time.current,
        rejection_reason: reason,
        player_confirmation_token: nil
      )

      TransferRequestMailer.rejected_notification(tr).deliver_later
      render json: tr.as_json
    end

    def approve_lv
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'pending_lv'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      if tr.request_type == 'release'
        tr.execute_release!(current_user.id)
      elsif tr.effective_date.nil? || tr.effective_date <= Date.today
        tr.execute_transfer!(current_user.id)
      else
        tr.update!(
          status: 'scheduled',
          approved_by_lv_user_id: current_user.id,
          lv_approved_at: Time.current
        )
      end

      render json: tr.as_json
    end

    def revoke
      tr = find_transfer_request
      return unless tr

      unless tr.request_type == 'release'
        return render json: { error: 'Nur Freigaben koennen zurueckgezogen werden' }, status: :unprocessable_entity
      end

      unless tr.status == 'approved'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      reason = params[:revocation_reason]&.strip
      if reason.blank?
        return render json: { error: 'Begruendung ist erforderlich' }, status: :unprocessable_entity
      end

      tr.revoke_release!(current_user.id, reason)
      render json: tr.as_json
    end

    def execute
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'scheduled'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      if tr.effective_date.present? && tr.effective_date > Date.today
        return render json: { error: "Transfer wird erst am #{tr.effective_date.strftime('%d.%m.%Y')} wirksam" }, status: :unprocessable_entity
      end

      tr.execute_transfer!(current_user.id)
      render json: tr.as_json
    end

    def reject_lv
      tr = find_transfer_request
      return unless tr

      unless tr.status == 'pending_lv'
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || lv_authorized?(ph, tr)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      reason = params[:rejection_reason]&.strip
      if reason.blank?
        return render json: { error: 'Begruendung ist erforderlich' }, status: :unprocessable_entity
      end

      tr.update!(
        status: 'rejected_by_lv',
        rejected_by: current_user.id,
        rejected_at: Time.current,
        rejection_reason: reason,
        player_confirmation_token: nil
      )

      TransferRequestMailer.rejected_notification(tr).deliver_later
      render json: tr.as_json
    end

    def withdraw
      tr = find_transfer_request
      return unless tr

      unless %w[pending_club pending_player pending_lv].include?(tr.status)
        return render json: { error: 'Ungültiger Status fuer diese Aktion' }, status: :unprocessable_entity
      end

      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:vm]&.include?(tr.requesting_club_id)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      tr.update!(status: 'withdrawn', player_confirmation_token: nil)
      render json: tr.as_json
    end

    def player_approve
      tr = TransferRequest.find_by(player_confirmation_token: params[:token])
      base_url = 'https://saisonmanager.org/transfer-bestaetigung'

      unless tr
        return redirect_to "#{base_url}?result=error", allow_other_host: true
      end

      unless tr.status == 'pending_player'
        result = tr.status.in?(%w[pending_lv scheduled approved]) ? 'already_approved' : 'error'
        return redirect_to "#{base_url}?result=#{result}", allow_other_host: true
      end

      tr.update!(status: 'pending_lv', player_approved_at: Time.current)

      TransferRequestMailer.pending_lv_notification(tr).deliver_later
      TransferRequestMailer.clubs_informed_lv_pending(tr).deliver_later

      redirect_to "#{base_url}?result=approved", allow_other_host: true
    end

    def player_reject
      tr = TransferRequest.find_by(player_confirmation_token: params[:token])
      base_url = 'https://saisonmanager.org/transfer-bestaetigung'

      unless tr
        return redirect_to "#{base_url}?result=error", allow_other_host: true
      end

      unless tr.status == 'pending_player'
        result = tr.status == 'rejected_by_player' ? 'already_rejected' : 'error'
        return redirect_to "#{base_url}?result=#{result}", allow_other_host: true
      end

      tr.update!(status: 'rejected_by_player', player_rejected_at: Time.current, player_confirmation_token: nil)

      TransferRequestMailer.player_rejected_clubs_notification(tr).deliver_later

      redirect_to "#{base_url}?result=rejected", allow_other_host: true
    end

    private

    def authorize_transfer_access!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def find_transfer_request
      tr = TransferRequest.find_by(id: params[:id])
      render json: { error: 'Nicht gefunden' }, status: :not_found unless tr
      tr
    end

    def lv_authorized?(ph, tr)
      return false unless ph[:sbk].present?
      return true if ph[:sbk].include?(0)

      ph[:sbk].include?(tr.former_club.main_game_operation_id)
    end

    def derive_club_ids_for_go(go_ids)
      Club.all.select { |c| go_ids.include?(c.main_game_operation_id) }.map(&:id)
    end
  end
end
