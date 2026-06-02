module Admin
  class RefereeAssignmentsController < ApplicationController
    before_action :authenticate_user
    before_action :authorize_rsk!

    # GET /api/v2/admin/referee_assignments
    def index
      scope = RefereeAssignment.includes(
        :referee1, :referee2,
        game: { game_day: [:league, :arena, :club] }
      )

      # Serverseitiger LV-Scope: ein nicht-globaler RSK sieht nur Ansetzungen
      # für Spiele in seinem game_operation-Scope (analog zu #games).
      ph = current_user.permission_hash
      unless ph[:admin].present? || (ph[:rsk].present? && ph[:rsk].include?(0))
        scoped_game_ids = Game.joins(game_day: :league)
                              .where(leagues: { game_operation_id: ph[:rsk] || [] })
                              .select(:id)
        scope = scope.where(game_id: scoped_game_ids)
      end

      if params[:game_operation_id].present?
        scope = scope.joins(game: { game_day: :league })
                     .where(leagues: { game_operation_id: params[:game_operation_id] })
      end

      if params[:season_id].present?
        scope = scope.joins(game: { game_day: :league })
                     .where(leagues: { season_id: params[:season_id] })
      end

      if params[:date_from].present?
        scope = scope.joins(game: :game_day)
                     .where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", params[:date_from])
      end

      if params[:date_to].present?
        scope = scope.joins(game: :game_day)
                     .where("TO_DATE(game_days.date, 'YYYY-MM-DD') <= ?", params[:date_to])
      end

      render json: scope.map { |a| assignment_json(a) }
    end

    # GET /api/v2/admin/referee_assignments/games?season_id=X&date_from=Y&date_to=Z
    def games
      ph = current_user.permission_hash
      go_ids = ph[:admin].present? ? nil : (ph[:rsk] || [])

      scope = Game.includes(
        :home_team, :guest_team, :referee_assignment,
        game_day: [:league, :arena, :club]
      ).joins(game_day: :league)

      unless go_ids.nil?
        if go_ids.include?(0)
          # global RSK access – no additional filter
        else
          scope = scope.where(leagues: { game_operation_id: go_ids })
        end
      end

      scope = scope.where(leagues: { season_id: params[:season_id] }) if params[:season_id].present?

      if params[:date_from].present?
        scope = scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", params[:date_from])
      end
      if params[:date_to].present?
        scope = scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') <= ?", params[:date_to])
      end

      scope = scope.order("game_days.date ASC, games.start_time ASC NULLS LAST")

      render json: scope.map { |g|
        a = g.referee_assignment
        {
          id: g.id,
          game_number: g.game_number,
          date: g.game_day.date,
          start_time: g.start_time,
          home_team: g.home_team&.name,
          guest_team: g.guest_team&.name,
          league: g.game_day.league&.name,
          arena: g.game_day.arena&.name,
          arena_postcode: g.game_day.arena&.postcode,
          arena_city: g.game_day.arena&.city,
          assignment_id: a&.id,
          assignment_status: a&.status
        }
      }
    end

    # GET /api/v2/admin/referee_assignments/available?date=YYYY-MM-DD&game_id=X
    def available
      date = Date.parse(params[:date]) rescue nil
      return render json: { error: 'Ungültiges Datum' }, status: :bad_request unless date

      game = Game.find_by(id: params[:game_id])
      is_cup = game&.league&.league_category_id.to_s.in?(%w[3 4])

      blocked_ids = RefereeBlockedDate.where(date: date).pluck(:referee_id)

      if is_cup
        # For cup games, only blocked-date conflicts apply
        assigned_ids = []
      else
        assigned_ids = RefereeAssignment
          .where(status: %w[tentative published])
          .joins(game: :game_day)
          .where("TO_DATE(game_days.date, 'YYYY-MM-DD') = ?", date)
          .pluck(:referee1_id, :referee2_id)
          .flatten
          .compact
      end

      unavailable = (blocked_ids + assigned_ids).uniq

      referees = Referee.where.not(id: unavailable)
                        .where(guest: false)
                        .order(:nachname, :vorname)

      render json: referees.map { |r|
        {
          id: r.id,
          lizenznummer: r.lizenznummer,
          lizenznummer_display: r.lizenznummer_display,
          vorname: r.vorname,
          nachname: r.nachname,
          lizenzstufe: r.lizenzstufe,
          partner_lizenznummer: r.partner_lizenznummer
        }
      }
    end

    # POST /api/v2/admin/referee_assignments
    def create
      return unless authorize_game_scope!(Game.find_by(id: assignment_params[:game_id]))

      assignment = RefereeAssignment.new(assignment_params)
      assignment.created_by = current_user.id
      assignment.updated_by = current_user.id

      if assignment.save
        render json: assignment_json(assignment.reload), status: :created
      else
        render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referee_assignments/:id
    def update
      assignment = RefereeAssignment.find(params[:id])
      # Sowohl das bestehende als auch das Ziel-Spiel müssen im Scope liegen
      # (game_id ist über assignment_params änderbar).
      return unless authorize_game_scope!(assignment.game)

      target_game_id = assignment_params[:game_id]
      return if target_game_id.present? && !authorize_game_scope!(Game.find_by(id: target_game_id))

      assignment.updated_by = current_user.id

      if assignment.update(assignment_params)
        render json: assignment_json(assignment.reload)
      else
        render json: { errors: assignment.errors.full_messages }, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    # POST /api/v2/admin/referee_assignments/:id/notify
    def notify
      assignment = RefereeAssignment.find(params[:id])
      return unless authorize_game_scope!(assignment.game)
      date = Date.parse(assignment.game.game_day.date) rescue nil

      assignment.referees.each do |referee|
        next unless referee.email.present?
        RefereeMailer.tentative_assignment_notification(referee, date).deliver_later
      end

      assignment.update_column(:notified_tentative_at, Time.current)
      render json: assignment_json(assignment.reload)
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    # POST /api/v2/admin/referee_assignments/:id/publish
    def publish
      assignment = RefereeAssignment.find(params[:id])
      game = assignment.game
      raise ActiveRecord::RecordNotFound unless game

      return unless authorize_game_scope!(game)

      parts = assignment.referees.map do |r|
        [r.lizenznummer_display.presence, "#{r.nachname}, #{r.vorname}"].compact.join(' ')
      end

      ActiveRecord::Base.transaction do
        assignment.update!(status: 'published', published_at: Time.current, updated_by: current_user.id)
        game.update!(nominated_referee_string: parts.join(' / ')) if parts.any?
      end

      expires_at = 72.hours.from_now
      license_token = Rails.application.message_verifier('license_list').generate(
        { game_id: assignment.game_id, expires_at: expires_at.iso8601 },
        expires_in: 72.hours
      )
      frontend_base = Rails.env.production? ? 'https://saisonmanager.org' : 'http://localhost:4200'
      license_list_url = "#{frontend_base}/lizenzliste?token=#{CGI.escape(license_token)}"

      assignment.referees.each do |referee|
        next unless referee.email.present?
        partner = assignment.referees.find { |r| r.id != referee.id }
        RefereeMailer.published_assignment_notification(
          referee,
          game,
          partner,
          game.game_day.club&.contact_email,
          license_list_url:,
          license_expires_at: expires_at
        ).deliver_later
      end

      render json: assignment_json(assignment.reload)
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    def authorize_rsk!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:rsk].present?
      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Fine-grained: Ein nicht-globaler RSK darf nur Spiele in seinem
    # game_operation-Scope ansetzen/benachrichtigen/veröffentlichen.
    # Gibt false zurück und rendert 403, wenn das Spiel außerhalb des Scopes liegt.
    def authorize_game_scope!(game)
      unless game
        render json: { error: 'Spiel nicht gefunden' }, status: :not_found
        return false
      end

      ph = current_user.permission_hash
      return true if ph[:admin].present?
      return true if ph[:rsk].present? && ph[:rsk].include?(0)

      go_id = game.game_day&.league&.game_operation_id
      return true if go_id.present? && (ph[:rsk] || []).include?(go_id)

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
      false
    end

    def assignment_params
      params.require(:assignment).permit(:game_id, :referee1_id, :referee2_id, :status)
    end

    def assignment_json(a)
      {
        id: a.id,
        game_id: a.game_id,
        status: a.status,
        notified_tentative_at: a.notified_tentative_at&.iso8601,
        published_at: a.published_at&.iso8601,
        referee1: a.referee1 ? referee_stub(a.referee1) : nil,
        referee2: a.referee2 ? referee_stub(a.referee2) : nil,
        game: game_stub(a.game)
      }
    end

    def referee_stub(r)
      {
        id: r.id,
        lizenznummer_display: r.lizenznummer_display,
        vorname: r.vorname,
        nachname: r.nachname,
        lizenzstufe: r.lizenzstufe,
        partner_lizenznummer: r.partner_lizenznummer
      }
    end

    def game_stub(g)
      return nil unless g
      {
        id: g.id,
        game_number: g.game_number,
        date: g.game_day.date,
        home_team: g.home_team&.name,
        guest_team: g.guest_team&.name,
        league: g.league&.name,
        league_category_id: g.league&.league_category_id,
        season_id: g.game_day.league&.season_id,
        arena: g.game_day.arena&.name,
        arena_postcode: g.game_day.arena&.postcode,
        arena_city: g.game_day.arena&.city,
        club: g.game_day.club&.name,
        result: g.result_string
      }
    end
  end
end
