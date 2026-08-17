module Admin
  # Ansprechpersonen der Vereine und Mannschaften der laufenden Saison,
  # gebündelt für die Spielbetriebskommission.
  #
  # Die Angaben liegen längst im Saisonmanager, nur verstreut: der Verein hat
  # eine Kontaktadresse und die unter „Zusätzlich informieren" ausgewählten
  # Vereinsmanager, die Mannschaft eine Kontaktperson und Teammanager-Konten.
  # Wer sie bisher zusammentragen wollte, klickte sich durch die
  # Vereinsverwaltung und die Benutzerliste, weshalb dieselben Angaben vor jeder
  # Saison zusätzlich per Umfrage eingesammelt wurden.
  #
  # Gruppiert wird nach Verein, weil die Mannschaft an ihm hängt. Der Zuschnitt
  # kommt dagegen über die Ligen: Maßgeblich ist, wer im Spielbetrieb der
  # Kommission spielt, nicht, wo ein Verein beheimatet ist. Sonst fehlten
  # genau die Gastmannschaften aus anderen Landesverbänden, für die die
  # Kommission die Saison über zuständig ist.
  #
  # Auf Vereinsebene ist die Auswahl dieselbe wie beim Versand der Vereinspost
  # (Club#notification_emails): die Kontaktadresse plus die ausdrücklich
  # markierten Vereinsmanager. Wer nicht markiert ist, hat die Rolle, aber nicht
  # die Zuständigkeit für den Schriftverkehr, und gehört deshalb nicht in eine
  # Liste, aus der Serienmails entstehen.
  class ContactsController < ApplicationController
    VM_ROLE_ID = 4
    TM_ROLE_ID = 5

    before_action :authorize_contact_view!

    # GET /api/v2/admin/contacts
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
      @season_id ||= Setting.current_season_id.to_s
    end

    # League.unscoped, weil der default_scope der Liga eine Sortierung mitbringt,
    # die in dieser Unterabfrage nichts zu suchen hat.
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
        notify_managers: notify_managers_for(club, vm_by_club),
        teams: club_teams.map { |team| team_hash(team, tm_by_team) }
      }
    end

    # Nur die unter „Zusätzlich informieren" markierten Vereinsmanager. Die
    # gespeicherten IDs werden dabei gegen die heutigen Rollen aufgelöst, wie
    # beim Versand auch: Wer die Rolle verloren hat, verschwindet, ohne dass
    # jemand die Markierung anfassen muss.
    def notify_managers_for(club, vm_by_club)
      marked = Array(club.notify_user_ids).map(&:to_i).to_set
      (vm_by_club[club.id] || []).uniq { |m| m[:id] }.select { |m| marked.include?(m[:id]) }
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
    #
    # Beide Typvarianten abfragen, wie Club#club_managers: jsonb-Containment ist
    # typstreng, `@> '[{"user_group_id":4}]'` findet einen Alt-Eintrag mit `"4"`
    # nicht, und die Person fehlte dann kommentarlos in der Liste.
    def contact_users
      @contact_users ||= User.not_archived.where(
        'permissions @> ? OR permissions @> ? OR permissions @> ? OR permissions @> ?',
        [{ user_group_id: VM_ROLE_ID }].to_json, [{ user_group_id: VM_ROLE_ID.to_s }].to_json,
        [{ user_group_id: TM_ROLE_ID }].to_json, [{ user_group_id: TM_ROLE_ID.to_s }].to_json
      ).order(:last_name, :first_name).to_a
    end

    # Zuordnung wie User#permission_hash[:vm], nur ohne dessen Query je Konto:
    # maßgeblich ist der club_id der Rollen-Berechtigung, nicht die Spalte
    # users.club_id. Beide können auseinanderlaufen, und ein Konto kann mehrere
    # Vereine führen.
    def group_managers_by_club(users)
      result = Hash.new { |hash, key| hash[key] = [] }
      users.each do |user|
        user.permissions.each do |perm|
          next unless perm['user_group_id'].to_i == VM_ROLE_ID
          next if perm['club_id'].blank?

          result[perm['club_id'].to_i] << manager_hash(user)
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
