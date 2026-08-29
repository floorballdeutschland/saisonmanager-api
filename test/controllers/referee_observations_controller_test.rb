require 'test_helper'

class RefereeObservationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @b_type = RefereeQualificationType.create!(name: 'B-Coach', short_name: 'B', active: true)
    @sa = create(:state_association, referee_assignment_external_enabled: true,
                                     referee_assignment_enabled: true)
    @go = create(:game_operation, state_association: @sa)
    @league = create(:league, game_operation: @go)
    @game_day = create(:game_day, league: @league,
                                  date: (RefereeObservationPolicy::ZONE.today - 5).strftime('%Y-%m-%d'))
    @referee1 = create(:referee, vorname: 'Anna', nachname: 'Schiri', email: 'anna@example.org')
    @referee2 = create(:referee, vorname: 'Bo', nachname: 'Pfiff', email: 'bo@example.org')
    @game = create(:game, game_day: @game_day,
                          officiating_referee_ids: [@referee1.id, @referee2.id])

    @coach = create(:referee, vorname: 'Cem', nachname: 'Coach')
    RefereeQualification.create!(referee: @coach, referee_qualification_type: @b_type, valid_until: nil)
    RefereeAssignment.create!(game: @game, coach: @coach, status: 'published')
    @coach_user = referee_user(@coach)
  end

  test 'angesetzter Coach gibt einen Bogen ab' do
    login(@coach_user)
    assert_difference 'RefereeObservation.count', 1 do
      post '/api/v2/referee/observations', params: payload, as: :json
    end
    assert_response :created

    observation = RefereeObservation.last
    assert_equal @go.id, observation.game_operation_id
    assert_equal 'Cem Coach', observation.coach_name
    assert_equal [@referee1.id, @referee2.id].sort, observation.ratings.map(&:referee_id).sort
    assert_equal 6, observation.ratings.find { |r| r.referee_id == @referee1.id }.overall_rating
    assert_equal 3, observation.ratings.find { |r| r.referee_id == @referee2.id }.overall_rating
  end

  test 'zweite Abgabe legt keinen zweiten Bogen an und liefert den ersten zurueck' do
    login(@coach_user)
    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :created
    first_id = JSON.parse(response.body)['id']

    assert_no_difference 'RefereeObservation.count' do
      post '/api/v2/referee/observations', params: payload, as: :json
    end
    assert_response :success
    assert_equal first_id, JSON.parse(response.body)['id']
  end

  test 'unvollstaendiger Bogen wird abgewiesen' do
    login(@coach_user)
    broken = payload
    broken[:final_comments] = ''
    assert_no_difference 'RefereeObservation.count' do
      post '/api/v2/referee/observations', params: broken, as: :json
    end
    assert_response :unprocessable_entity
  end

  test 'Coach ohne Ansetzung bekommt 403' do
    other_coach = create(:referee)
    RefereeQualification.create!(referee: other_coach, referee_qualification_type: @b_type)
    login(referee_user(other_coach))

    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :forbidden
  end

  test 'Abgabe benachrichtigt beide beobachteten Schiedsrichter' do
    # Die Mail geht an die Adresse am Schiedsrichterdatensatz; das Konto
    # entscheidet nur, OB benachrichtigt wird (receive_info_mails).
    referee_user(@referee1)
    referee_user(@referee2)
    login(@coach_user)

    assert_difference 'ActionMailer::Base.deliveries.size', 2 do
      perform_enqueued_jobs do
        post '/api/v2/referee/observations', params: payload, as: :json
      end
    end
  end

  test 'beobachtete Person sieht ihre eigenen Bewertungen, nicht die des Partners' do
    login(@coach_user)
    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :created

    login(referee_user(@referee1))
    get '/api/v2/referee/observations/received'
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal 1, body.size
    assert_equal([@referee1.id], body.first['ratings'].map { |r| r['referee_id'] })
    # Gemeinsame Teile bleiben sichtbar – sie sind der Kern der Rueckmeldung.
    assert_equal 5, body.first['pair_overall_rating']
    assert body.first['final_comments'].present?
  end

  test 'zurueckgenommener Bogen verschwindet aus der Sicht der beobachteten Person' do
    observation = create(:referee_observation, :with_rating, rated_referee: @referee1,
                                                            status: 'hidden')
    assert observation.persisted?

    login(referee_user(@referee1))
    get '/api/v2/referee/observations/received'
    assert_response :success
    assert_empty JSON.parse(response.body)
  end

  test 'Spielauswahl listet das angesetzte Spiel und markiert abgegebene Boegen' do
    login(@coach_user)
    get '/api/v2/referee/observations/games'
    assert_response :success

    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert entry, 'Das angesetzte Spiel muss zur Auswahl stehen'
    assert entry['assigned_as_coach']
    assert_equal false, entry['done']
    assert_equal([@referee1.id, @referee2.id], entry['referees'].map { |r| r['referee_id'] })

    post '/api/v2/referee/observations', params: payload, as: :json
    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert entry['done']
  end

  test 'Coach sieht den eigenen zurueckgenommenen Bogen weiterhin' do
    observation = create(:referee_observation, :with_rating, coach: @coach, status: 'hidden')
    login(@coach_user)

    get '/api/v2/referee/observations'
    assert_response :success
    assert_equal([observation.id], JSON.parse(response.body).map { |o| o['id'] })
  end

  # Die freie Auswahl trifft ohne Einschraenkung jedes Spiel des Spielbetriebs im
  # Rueckblickfenster. Ein Spiel ohne eingetragenes Gespann kann dabei nur im
  # Fehler enden (RefereeObservationSubmission::NO_REFEREES_ERROR) und wird
  # deshalb gar nicht erst angeboten.
  test 'freie Auswahl listet Spiele mit Gespann und laesst Spiele ohne Gespann weg' do
    free_sa = create(:state_association, referee_assignment_external_enabled: false)
    free_go = create(:game_operation, state_association: free_sa)
    free_league = create(:league, game_operation: free_go)
    free_day = create(:game_day, league: free_league,
                                 date: (RefereeObservationPolicy::ZONE.today - 3).strftime('%Y-%m-%d'))
    with_crew = create(:game, game_day: free_day,
                              officiating_referee_ids: [@referee1.id, @referee2.id])
    without_crew = create(:game, game_day: free_day, officiating_referee_ids: [])
    @coach.update!(game_operation_id: free_go.id)

    login(@coach_user)
    get '/api/v2/referee/observations/games'
    assert_response :success

    ids = JSON.parse(response.body).map { |g| g['game_id'] }
    assert_includes ids, with_crew.id
    assert_not_includes ids, without_crew.id
    assert_includes ids, @game.id, 'Das angesetzte Spiel bleibt unabhaengig davon in der Liste'
  end

  test 'personenscharf angesetzter Spielbetrieb bietet keine freie Auswahl an' do
    other = create(:game, game_day: @game_day,
                          officiating_referee_ids: [@referee1.id, @referee2.id])
    @coach.update!(game_operation_id: @go.id)

    login(@coach_user)
    get '/api/v2/referee/observations/games'
    assert_response :success

    ids = JSON.parse(response.body).map { |g| g['game_id'] }
    assert_includes ids, @game.id
    assert_not_includes ids, other.id
  end

  test 'Konto ohne Schiedsrichterprofil bekommt 403' do
    login(create(:user, :admin))
    get '/api/v2/referee/observations'
    assert_response :forbidden
  end

  private

  def payload
    {
      game_id: @game.id,
      match_description: 'Kopf-an-Kopf-Spiel.',
      stick_play_comment: 'Stocklinie einheitlich.',
      physical_play_comment: 'Koerperspiel frueh eingefangen.',
      penalty_line_comment: 'Strafen nachvollziehbar.',
      game_management_comment: 'Ruhige Leitung.',
      other_matters: 'Nichts Besonderes.',
      final_comments: 'Kommunikation im Gespann ausbauen.',
      pair_stick_play_rating: 5,
      pair_physical_play_rating: 5,
      pair_penalty_line_rating: 4,
      pair_game_management_rating: 5,
      pair_overall_rating: 5,
      ratings: [
        { referee_id: @referee1.id, stick_play_rating: 6, physical_play_rating: 6,
          penalty_line_rating: 5, game_management_rating: 6, overall_rating: 6 },
        { referee_id: @referee2.id, stick_play_rating: 3, physical_play_rating: 4,
          penalty_line_rating: 3, game_management_rating: 3, overall_rating: 3 }
      ]
    }
  end

  def referee_user(referee)
    User.create!(
      user_name: "sr_#{SecureRandom.hex(4)}",
      password: 'password123', password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: [], referee: referee
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
