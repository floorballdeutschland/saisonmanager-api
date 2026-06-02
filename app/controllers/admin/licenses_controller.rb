module Admin
  class LicensesController < ApplicationController
    def index
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { message: 'Keine Berechtigung!' }, status: :forbidden
      end

      season_id = params[:season_id].presence || Setting.current_season_id

      # All leagues for this season – needed for correct primary/secondary computation across all of a player's licenses
      all_season_leagues = League.where(season_id: season_id).index_by(&:id)
      # team_id → league_id map for primary/secondary sorting
      team_league_id_map = Team.where(league_id: all_season_leagues.keys).pluck(:id, :league_id).to_h

      # Filtered scope for the result set
      leagues = League.where(id: all_season_leagues.keys)
      leagues = leagues.where(game_operation_id: params[:game_operation_id].to_i) if params[:game_operation_id].present?
      unless ph[:admin].present?
        go_ids = ph[:sbk].include?(0) ? nil : ph[:sbk]
        leagues = leagues.where(game_operation_id: go_ids) if go_ids
      end

      leagues         = leagues.to_a
      game_operations = GameOperation.where(id: leagues.map(&:game_operation_id).uniq).index_by(&:id)
      team_club_map   = Team.where(league_id: leagues.map(&:id)).pluck(:id, :club_id).to_h
      clubs           = Club.where(id: team_club_map.values.uniq).index_by(&:id)

      # Pre-load all license documents for players in these leagues (grouped by [player_id, license_id, doc_type])
      all_player_ids = leagues.flat_map { |l| l.licenses(true, true).flat_map { |t| t[:players].map { |p| p[:id] } } }.uniq
      license_docs_by_key = LicenseDocument.where(player_id: all_player_ids)
                                           .includes(file_attachment: :blob)
                                           .group_by { |d| [d.player_id, d.license_id, d.document_type] }

      result = []
      leagues.each do |league|
        game_op       = game_operations[league.game_operation_id]
        category_name = license_category_name(league.league_category_id)
        class_name    = license_class_name(league.league_class_id)

        league.licenses(true, true).each do |team_data|
          club = clubs[team_club_map[team_data[:id]]]

          team_data[:players].each do |player_data|
            lic = player_data[:team_license][:license]
            unless lic
              Rails.logger.error("Admin::LicensesController: nil license for player #{player_data[:id]} in team #{team_data[:id]}")
              next
            end
            last_status_id = player_data[:team_license][:last_status_id].to_i

            result << {
              player_id:            player_data[:id],
              player_last_name:     player_data[:last_name],
              player_first_name:    player_data[:first_name],
              player_birthdate:     player_data[:birthdate],
              player_gender:        player_data[:gender],
              club_id:              club&.id,
              club_name:            club&.name,
              team_id:              team_data[:id],
              team_name:            team_data[:name],
              league_id:            league.id,
              league_name:          league.name,
              field_size:           league.field_size,
              female:               league.female,
              age_group:            league.age_group,
              league_category_id:   league.league_category_id,
              league_category_name: category_name,
              league_class_id:      league.league_class_id,
              league_class_name:    class_name,
              league_type:          league.league_type,
              league_modus:         league.league_modus,
              game_operation_id:    game_op&.id,
              game_operation_name:  game_op&.name,
              season_id:            league.season_id,
              license_id:           lic['id'],
              license_type:         license_type(player_data[:licenses], lic, all_season_leagues, team_league_id_map),
              license_status_id:    last_status_id,
              license_status:       License::NAMES[last_status_id],
              express:              lic['express'] || false,
              requested_at:         player_data[:team_license][:requested_at],
              approved_at:          player_data[:team_license][:approved_at],
              required_documents:   league.required_documents || [],
              valid_until:          lic['valid_until'],
              documents:            documents_for(player_data[:id], lic['id'], license_docs_by_key, league.required_documents)
            }
          end
        end
      end

      render json: result
    end

    private

    def documents_for(player_id, license_id, docs_by_key, required_documents = [])
      id_copy_docs          = docs_by_key[[player_id, license_id, 'id_copy']]
      parental_consent_docs = docs_by_key[[player_id, license_id, 'parental_consent']]
      result = {
        id_copy:              id_copy_docs.present?,
        parental_consent:     parental_consent_docs.present?,
        id_copy_url:          id_copy_docs&.first&.then { |d| rails_blob_url(d.file, disposition: 'inline') if d.file.attached? },
        parental_consent_url: parental_consent_docs&.first&.then { |d| rails_blob_url(d.file, disposition: 'inline') if d.file.attached? }
      }

      (Array(required_documents) - %w[id_copy parental_consent]).each do |doc_type|
        docs = docs_by_key[[player_id, license_id, doc_type]]
        result[doc_type.to_sym]             = docs.present?
        result["#{doc_type}_url".to_sym]    = docs&.first&.then { |d| rails_blob_url(d.file, disposition: 'inline') if d.file.attached? }
      end

      result
    end

    def license_type(player_lics, current_lic, all_season_leagues, team_league_id_map)
      lics = Array(player_lics).select { |l| team_league_id_map.key?(l['team_id'].to_i) }
      return 'primary' if lics.size <= 1

      primary_id = lics
        .sort_by do |l|
          league_id = team_league_id_map[l['team_id'].to_i]
          lg        = all_season_leagues[league_id]
          cat = lg&.league_category_id.to_s.rjust(3, '0')
          cls = lg&.league_class_id.to_s.rjust(3, '0')
          (cat + cls).to_i
        end
        .first&.fetch('id', current_lic['id'])

      primary_id == current_lic['id'] ? 'primary' : 'secondary'
    end

    def license_category_name(category_id)
      return nil if category_id.blank?

      Setting.current['league_categories']&.dig(category_id.to_s, 'name') || category_id
    end

    def license_class_name(class_id)
      return nil if class_id.blank?

      Setting.current['league_classes']&.dig(class_id.to_s, 'name') || class_id
    end
  end
end
