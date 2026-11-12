require 'test_helper'

# Ein hochgeladenes Protestformular ist etwas Neues für die SBK: Ein schon
# gesetzter Erledigt-Vermerk gilt danach nicht mehr.
class GameReportLastChangeProtestTest < ActiveSupport::TestCase
  test 'der Eingang eines Protestformulars zählt als jüngste Änderung' do
    create(:setting)
    league = create(:league, game_operation: create(:game_operation, state_association_id: create(:state_association).id))
    club = create(:club)
    game_day = GameDay.create!(league:, arena: create(:arena), club:, number: 1, date: '2026-11-08')
    game = Game.create!(game_day:, home_team: create(:team, league:, club:),
                        guest_team: create(:team, league:, club: create(:club)),
                        forfait: 0, overtime: false, legacy: false, events: [],
                        players: { 'home' => [], 'guest' => [] },
                        record_updated_at: 2.days.ago, protest: true, protest_parties: %w[guest])
    protest, = GameProtest.create_with_token!(game:, party: 'guest', recipients: [])
    eingang = 1.hour.ago.change(usec: 0)
    protest.update_columns(submitted_at: eingang)

    assert_equal eingang, GameReportLastChange.for(game.reload)
  end
end
