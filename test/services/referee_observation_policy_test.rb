require 'test_helper'

# Wer darf beobachten, wer darf lesen. Die Rechte des Beobachtungsbogens liegen
# an genau einer Stelle (RefereeObservationPolicy); dieser Test ist ihre
# Wahrheitstabelle.
class RefereeObservationPolicyTest < ActiveSupport::TestCase
  setup do
    @b_type = RefereeQualificationType.create!(name: 'B-Coach', short_name: 'B', active: true)
    @past = RefereeObservationPolicy::ZONE.today - 7
  end

  test 'angesetzter Coach darf beobachten' do
    game = game_on(@past)
    coach = coach_referee
    RefereeAssignment.create!(game: game, coach: coach, status: 'published')

    assert policy_for(coach).can_observe?(game)
  end

  test 'ohne Ansetzung und mit personenscharfer Ansetzung im Verband darf niemand frei waehlen' do
    game = game_on(@past, assignment_mode: :person)
    coach = coach_referee(club: create(:club, game_operation: game.league.game_operation))

    assert_not policy_for(coach).can_observe?(game)
  end

  test 'ohne personenscharfe Ansetzung darf der Coach ein Spiel des eigenen Spielbetriebs waehlen' do
    game = game_on(@past, assignment_mode: :none)
    coach = coach_referee(club: create(:club, game_operation: game.league.game_operation))

    assert policy_for(coach).can_observe?(game)
  end

  test 'fremder Spielbetrieb bleibt auch ohne Ansetzung gesperrt' do
    game = game_on(@past, assignment_mode: :none)
    coach = coach_referee(club: create(:club, game_operation: create(:game_operation)))

    assert_not policy_for(coach).can_observe?(game)
  end

  test 'ohne gueltige B-Zusatzqualifikation darf auch der angesetzte Coach nicht' do
    game = game_on(@past)
    coach = create(:referee)
    RefereeQualification.create!(referee: coach, referee_qualification_type: @b_type,
                                 valid_until: @past - 1)
    RefereeAssignment.create!(game: game, coach: coach, status: 'published')

    assert_not policy_for(coach).can_observe?(game)
  end

  test 'gemessen wird am Spieltag, nicht an heute' do
    game = game_on(@past)
    # Am Spieltag noch gueltig, inzwischen abgelaufen: Der Bogen zu diesem Spiel
    # bleibt moeglich. Wuerde gegen Date.current geprueft, waere er gesperrt.
    coach = coach_referee(valid_until: @past)
    RefereeAssignment.create!(game: game, coach: coach, status: 'published')

    policy = policy_for(coach)
    assert policy.can_observe?(game)
    assert_not policy.coach_qualified?, 'Heute ist die Qualifikation abgelaufen'
  end

  test 'zukuenftige Spiele sind gesperrt' do
    future = RefereeObservationPolicy::ZONE.today + 3
    game = game_on(future)
    coach = coach_referee
    RefereeAssignment.create!(game: game, coach: coach, status: 'published')

    assert_not policy_for(coach).can_observe?(game)
  end

  test 'Konto ohne Schiedsrichterprofil darf nicht beobachten' do
    game = game_on(@past)
    user = create(:user)

    assert_not RefereeObservationPolicy.new(user).can_observe?(game)
  end

  # --- Lesesicht ---

  test 'beobachtete Person sieht ihren Bogen, aber keinen zurueckgenommenen' do
    referee = create(:referee)
    visible = create(:referee_observation, :with_rating, rated_referee: referee)
    hidden = create(:referee_observation, :with_rating, rated_referee: referee, status: 'hidden')
    user = user_for(referee)

    ids = RefereeObservationPolicy.new(user).visible_scope.pluck(:id)
    assert_includes ids, visible.id
    assert_not_includes ids, hidden.id
  end

  test 'Coach sieht den eigenen Bogen auch zurueckgenommen' do
    coach = create(:referee)
    hidden = create(:referee_observation, :with_rating, coach: coach, status: 'hidden')

    ids = RefereeObservationPolicy.new(user_for(coach)).visible_scope.pluck(:id)
    assert_includes ids, hidden.id
  end

  test 'LV-RSK sieht nur Boegen des eigenen Spielbetriebs' do
    own = create(:referee_observation, :with_rating)
    other = create(:referee_observation, :with_rating)
    user = create(:user, :rsk_scoped, game_operation_id: own.game_operation_id)

    ids = RefereeObservationPolicy.new(user).visible_scope.pluck(:id)
    assert_includes ids, own.id
    assert_not_includes ids, other.id
  end

  test 'Admin sieht alles' do
    one = create(:referee_observation, :with_rating)
    two = create(:referee_observation, :with_rating)

    ids = RefereeObservationPolicy.new(create(:user, :admin)).visible_scope.pluck(:id)
    assert_includes ids, one.id
    assert_includes ids, two.id
  end

  test 'unbeteiligter Schiedsrichter sieht nichts' do
    create(:referee_observation, :with_rating)
    user = user_for(create(:referee))

    assert_empty RefereeObservationPolicy.new(user).visible_scope.pluck(:id)
  end

  private

  def policy_for(referee)
    RefereeObservationPolicy.new(user_for(referee))
  end

  def user_for(referee)
    create(:user, referee: referee, permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }])
  end

  def coach_referee(club: nil, valid_until: nil)
    referee = create(:referee, club: club)
    RefereeQualification.create!(referee: referee, referee_qualification_type: @b_type,
                                 valid_until: valid_until)
    referee
  end

  # :person – Landesverband setzt personenscharf an (Weg 2)
  # :none   – gar keine externe Ansetzung, der Coach darf frei waehlen
  def game_on(date, assignment_mode: :person)
    sa = create(:state_association,
                referee_assignment_external_enabled: assignment_mode != :none,
                referee_assignment_enabled: assignment_mode == :person)
    go = create(:game_operation, state_association: sa)
    league = create(:league, game_operation: go)
    game_day = create(:game_day, league: league, date: date.strftime('%Y-%m-%d'))
    create(:game, game_day: game_day)
  end
end
