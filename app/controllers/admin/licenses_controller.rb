module Admin
  class LicensesController < ApplicationController
    include LicenseDocumentPresentation

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
      # Wie League.license_teams_by_league auch die Mannschaften, die nur über
      # cup_leagues zur Liga gehören (Pokal/Endrunde). Ohne die Vereinigung blieb
      # deren Verein in der Lizenzübersicht leer: Die Zeilen kommen aus
      # League.licenses_for, das die Vereinigung kennt, der Verein aber aus dieser
      # Zuordnung, die nur league_id kannte. Betroffen war genau die Sicht der
      # Pokal-SBK, für die die Hauptliga der Mannschaft nicht in `leagues` steckt.
      league_ids      = leagues.map(&:id)
      team_club_map   = if league_ids.any?
                          Team.where(league_id: league_ids)
                              .or(Team.where('cup_leagues && ARRAY[?]::int[]', league_ids))
                              .pluck(:id, :club_id).to_h
                        else
                          {}
                        end
      clubs           = Club.where(id: team_club_map.values.uniq).index_by(&:id)

      # Die Lizenzlisten aller Ligen in einem Rutsch und genau einmal. Bisher lief
      # league.licenses zweimal – erst zum Sammeln der Spieler-IDs für die
      # Dokumente, dann erneut zum Bauen der Antwort – und beide Male Liga für
      # Liga, also je Liga eine eigene Spieler-Abfrage über die players-Tabelle.
      # Diese Liste liest weder Logos noch other_licenses noch das Freigabedatum,
      # daher :light und beide Schalter aus. with_release_dates: false spart eine
      # Abfrage ueber die Spieler ALLER Ligen der Saison.
      licenses_by_league = League.licenses_for(leagues, team_hash: :light, with_other_licenses: false,
                                               with_release_dates: false)

      # Pre-load all license documents for players in these leagues (grouped by
      # [player_id, doc_type] – Dokumente gelten pro Spieler, saisonübergreifend)
      all_player_ids = licenses_by_league.each_value.flat_map do |team_items|
        team_items.flat_map { |t| t[:players].map { |p| p[:id] } }
      end.uniq
      license_docs_by_key = license_documents_by_player_and_type(all_player_ids)
      catalog = document_type_catalog(leagues.flat_map { |l| league_required_document_keys(l) } + ['parental_consent'])

      result = []
      leagues.each do |league|
        game_op       = game_operations[league.game_operation_id]
        category_name = license_category_name(league.league_category_id)
        class_name    = license_class_name(league.league_class_id)
        league_keys   = league_required_document_keys(league)

        licenses_by_league.fetch(league.id, []).each do |team_data|
          club = clubs[team_club_map[team_data[:id]]]

          team_data[:players].each do |player_data|
            lic = player_data[:team_license][:license]
            unless lic
              Rails.logger.error("Admin::LicensesController: nil license for player #{player_data[:id]} in team #{team_data[:id]}")
              next
            end
            last_status_id = player_data[:team_license][:last_status_id].to_i
            # Altersabhängige Dokumentarten: Stichtag ist das Datum der Lizenzbeantragung.
            required_keys = DocumentType.required_keys(
              league_keys,
              birthdate: player_data[:birthdate],
              requested_at: player_data[:team_license][:requested_at]&.to_time,
              catalog: catalog
            )

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
              # Manuelle Erst-/Zweitlizenz-Zuordnung im GF-Erwachsenenbereich
              # ('erstlizenz' | 'zweitlizenz' | nil = nicht zugeordnet).
              gf_role:              lic['gf_role'],
              license_status_id:    last_status_id,
              license_status:       License::NAMES[last_status_id],
              # Der Status ohne Sperre und die Sperre selbst (#605). Bis dahin
              # verschwand eine gesperrte Lizenz ganz aus dieser Uebersicht,
              # statt ihren Status zu zeigen.
              base_status_id:       player_data[:team_license][:base_status_id].to_i,
              base_status:          License::NAMES[player_data[:team_license][:base_status_id].to_i],
              suspension:           player_data[:team_license][:suspension],
              express:              lic['express'] || false,
              requested_at:         player_data[:team_license][:requested_at],
              approved_at:          player_data[:team_license][:approved_at],
              # Datum der Vereins-Freigabe (genehmigter Freigabe-Antrag), leer
              # bei Spielern, die keine brauchten.
              released_at:          player_data[:team_license][:released_at],
              required_documents:   required_keys,
              valid_until:          lic['valid_until'],
              documents:            document_map_for(player_data[:id], league.season_id, license_docs_by_key, required_keys, catalog)
            }
          end
        end
      end

      render json: result
    end

    private

    # Haupt-/Zusatzlizenz (Anzeige-Konzept): die Lizenz in der höchsten Liga ist
    # 'primary', alle weiteren sind Zusatzlizenzen ('secondary'). Unabhängig von
    # der manuellen Erst-/Zweitlizenz-Zuordnung (gf_role), die die
    # Spielberechtigung im GF-Erwachsenenbereich dokumentiert.
    def license_type(player_lics, current_lic, all_season_leagues, team_league_id_map)
      lics = Array(player_lics).select { |l| team_league_id_map.key?(l['team_id'].to_i) }
      return 'primary' if lics.size <= 1

      primary_id = lics
        .sort_by do |l|
          league_id = team_league_id_map[l['team_id'].to_i]
          lg        = all_season_leagues[league_id]
          # Höchste Liga zuerst; bei gleicher Ligastufe die früher genehmigte.
          # l['id'] als letzter Tiebreaker, damit die Auswahl bei vollständigem
          # Gleichstand deterministisch ist (sort_by ist nicht stabil).
          [League.class_rank(lg&.league_class_id), License.approval_time(l), l['id'].to_s]
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
