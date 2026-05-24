FactoryBot.define do
  # Setting ist effektiv Singleton (`Setting.first`). Factory liefert ein
  # bewusst minimales Singleton, das in den meisten Tests reicht. Tests, die
  # eine bestimmte Saison als „aktuell" brauchen, übergeben current_season_id
  # explizit:
  #
  #   create(:setting, current_season_id: '18')
  #   create(:setting, current_season_id: '18', current_min_team: 1500)
  factory :setting do
    transient do
      current_season_id { '18' }
      current_min_team { nil } # nil → simuliert PR-#168-Fallback auf 0
      current_min_league { nil }
    end

    seasons do
      base = {
        '17' => { 'name' => 'Saison 2024/25' },
        '18' => { 'name' => 'Saison 2025/26' }
      }
      key = current_season_id.to_s
      if current_min_team || current_min_league
        base[key] = (base[key] || { 'name' => "Saison #{key}" }).merge(
          'min_team_id' => current_min_team,
          'min_league_id' => current_min_league
        )
      end
      base
    end

    # current_season_id wird sowohl als String („18") als auch als Int (18)
    # im Code gelesen. Im JSONB liegt es als Int — Saisons-Lookup über
    # Setting.seasons.map { |k| k.to_i == current_season_id } setzt das
    # voraus.
    systems { { '1' => { 'current_season_id' => current_season_id.to_i } } }
    nations { { '1' => { 'name' => 'Deutschland' } } }
    league_classes { {} }
    league_categories { {} }
    league_systems { {} }
    user_groups { {} }
    penalties { {} }
    penalty_codes { {} }
    point_corrections { {} }
    liveticker { {} }

    # Singleton: vor jedem Build alte Setting-Zeilen löschen, damit Tests
    # nicht versehentlich auf eine alte Setting-Instanz greifen.
    to_create do |instance|
      Setting.delete_all
      instance.save!
    end
  end
end
