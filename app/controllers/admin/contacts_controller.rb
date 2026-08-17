module Admin
  # Ansprechpersonen der Vereine und Mannschaften einer Saison, gebündelt für
  # die Spielbetriebskommission.
  #
  # Die Angaben liegen längst im Saisonmanager, nur verstreut: der Verein hat
  # eine Kontaktadresse und Vereinsmanager-Konten, die Mannschaft eine
  # Kontaktperson und Teammanager-Konten. Wer sie bisher zusammentragen wollte,
  # klickte sich durch die Vereinsverwaltung und die Benutzerliste – weshalb
  # dieselben Angaben vor jeder Saison zusätzlich per Umfrage eingesammelt
  # wurden.
  #
  # Gruppiert wird nach Verein, weil die Mannschaft an ihm hängt. Der Zuschnitt
  # kommt dagegen über die Ligen: Maßgeblich ist, wer im Spielbetrieb der
  # Kommission spielt, nicht, wo ein Verein beheimatet ist. Sonst fehlten
  # genau die Gastmannschaften aus anderen Landesverbänden, für die die
  # Kommission die Saison über zuständig ist.
  class ContactsController < ApplicationController
    VM_ROLE_ID = 4
    TM_ROLE_ID = 5

    before_action :authorize_contact_view!

    # GET /api/v2/admin/contacts(?season_id=18)
    def index
      teams = scoped_teams
      render json: {
        season_id: season_id,
        clubs: build_clubs(teams)
      }
    end

    private

    # Gleiche Ebene wie die Ligaverwaltung (menu_item_league_admin): Wer den
    # Spielbetrieb führt, führt auch den Schriftverkehr dazu.
    def authorize_contact_view!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def season_id
      # Frei wählbar, weil die Frage „wer ist Ansprechperson?" typischerweise
      # VOR der Saison gestellt wird, die Kommission also die kommende Saison
      # im Blick hat, während der Saisonmanager noch auf der laufenden steht.
      params[:season_id].presence&.to_s || Setting.current_season_id.to_s
    end

    def scoped_teams
      leagues = League.unscoped.where(season_id: season_id)
      ph = current_user.permission_hash
      go_ids = ph[:admin].present? ? nil : Array(ph[:sbk])
      leagues = leagues.where(game_operation_id: go_ids) unless go_ids.nil? || go_ids.include?(0)

      Team.where(league_id: leagues.select(:id))
          .includes(:club, :league)
          .order(:name)
    end

    def build_clubs(teams)
      users = contact_users
      vm_by_club = group_managers_by_club(users)
      tm_by_team = group_managers_by_team(users, teams.map(&:id))

      grouped = teams.group_by(&:club).filter_map do |club, club_teams|
        next unless club

        club_hash(club, club_teams, vm_by_club, tm_by_team)
      end

      grouped.sort_by { |club| club[:name].to_s }
    end

    def club_hash(club, club_teams, vm_by_club, tm_by_team)
      {
        id: club.id,
        name: club.name,
        contact_email: club.contact_email,
        state_association_name: state_association_names[club.state_association_id],
        managers: (vm_by_club[club.id] || []).uniq { |m| m[:id] },
        teams: club_teams.map { |team| team_hash(team, tm_by_team) }
      }
    end

    def team_hash(team, tm_by_team)
      {
        id: team.id,
        name: team.name,
        league_id: team.league_id,
        league_name: team.league&.name,
        game_operation_name: game_operation_names[team.league&.game_operation_id],
        contact_person: team.contact_person,
        contact_email: team.contact_email,
        managers: (tm_by_team[team.id] || []).uniq { |m| m[:id] }
      }
    end

    # Nur Konten mit Vereins- oder Teammanager-Rolle, und nur nicht archivierte:
    # Ein archiviertes Konto kann sich nicht mehr anmelden und ist als
    # Ansprechperson keine Auskunft, sondern eine Falle.
    def contact_users
      @contact_users ||= User.not_archived.where(
        "permissions @> '[{\"user_group_id\": #{VM_ROLE_ID}}]' " \
        "OR permissions @> '[{\"user_group_id\": #{TM_ROLE_ID}}]'"
      ).order(:last_name, :first_name).to_a
    end

    def group_managers_by_club(users)
      result = Hash.new { |hash, key| hash[key] = [] }
      users.each do |user|
        # Die Rollen-Berechtigung ist maßgeblich, nicht die Spalte users.club_id:
        # Beide können auseinanderlaufen, und ein Konto kann mehrere Vereine
        # führen (mehrere VM-Einträge).
        user.permissions.each do |perm|
          next unless perm['user_group_id'].to_i == VM_ROLE_ID

          club_id = perm['club_id'].presence&.to_i || user.club_id
          next unless club_id

          result[club_id] << manager_hash(user)
        end
      end
      result
    end

    def group_managers_by_team(users, team_ids)
      wanted = team_ids.to_set
      result = Hash.new { |hash, key| hash[key] = [] }
      users.each do |user|
        next unless user.permissions.any? { |p| p['user_group_id'].to_i == TM_ROLE_ID }

        Array(user.teams).each do |team_id|
          next unless wanted.include?(team_id)

          result[team_id] << manager_hash(user)
        end
      end
      result
    end

    def manager_hash(user)
      {
        id: user.id,
        name: user.fullname,
        username: user.user_name,
        email: user.email,
        last_login_at: user.last_login_at
      }
    end

    def state_association_names
      @state_association_names ||= StateAssociation.pluck(:id, :name).to_h
    end

    def game_operation_names
      @game_operation_names ||= GameOperation.pluck(:id, :name).to_h
    end
  end
end
