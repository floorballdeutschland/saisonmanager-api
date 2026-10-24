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
    RefereeQualification.create!(referee: @coach, referee_qualification_type: @b_type,
                                 valid_until: 1.year.from_now.to_date)
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
    RefereeQualification.create!(referee: other_coach, referee_qualification_type: @b_type,
                                 valid_until: 1.year.from_now.to_date)
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

  # Gast im Spielbericht: Freitext mit Lizenznummer 0, kein Referee-Datensatz.
  test 'Gast im Spielbericht wird nicht bewertet und steht als Hinweis im Gespann' do
    @game.update!(referee1_string: "#{@referee1.lizenznummer} Schiri, Anna",
                  referee2_string: '0 Gast, Gustav',
                  officiating_referee_ids: [@referee1.id, 0])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_equal([@referee1.id], entry['referees'].map { |r| r['referee_id'] })
    assert_equal ['Gustav Gast'], entry['unrated_referee_names']

    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :created
    assert_equal [@referee1.id], RefereeObservation.last.ratings.map(&:referee_id)
  end

  # Ohne auflösbaren Bericht greift die Ansetzung, und dort kann ein Gast als
  # Datensatz stehen. Bewertet wird er trotzdem nicht, auch wenn der Client eine
  # Bewertung für ihn mitschickt.
  test 'angesetzter Gast wird nicht bewertet, der Partner behaelt seinen Slot' do
    guest = create(:referee, vorname: 'Kamil', nachname: 'Gast', guest: true, lizenznummer: nil)
    @game.update!(officiating_referee_ids: [], nominated_referee_ids: [guest.id, @referee2.id])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_equal([[@referee2.id, 2]], entry['referees'].map { |r| [r['referee_id'], r['position']] })
    assert_equal ['Kamil Gast'], entry['unrated_referee_names']

    body = payload
    body[:ratings].first[:referee_id] = guest.id
    post '/api/v2/referee/observations', params: body, as: :json
    assert_response :created
    rating = RefereeObservation.last.ratings.sole
    assert_equal [@referee2.id, 2], [rating.referee_id, rating.position]
  end

  test 'Spiel mit reinem Gast-Gespann wird mit eigener Meldung abgewiesen' do
    guest = create(:referee, vorname: 'Kamil', nachname: 'Gast', guest: true, lizenznummer: nil)
    @game.update!(officiating_referee_ids: [], nominated_referee_ids: [guest.id])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_empty entry['referees']
    assert_equal ['Kamil Gast'], entry['unrated_referee_names']

    assert_no_difference 'RefereeObservation.count' do
      post '/api/v2/referee/observations', params: payload, as: :json
    end
    assert_response :unprocessable_entity
    assert_includes response.body, 'Gastschiedsrichter werden nicht einzeln bewertet'
  end

  test 'Gast auf Slot 1 im Spielbericht: Partner bleibt Schiedsrichter 2' do
    @game.update!(referee1_string: '0 Gast, Gustav',
                  referee2_string: "#{@referee2.lizenznummer} Pfiff, Bo",
                  officiating_referee_ids: [0, @referee2.id])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_equal([[@referee2.id, 2]], entry['referees'].map { |r| [r['referee_id'], r['position']] })

    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :created
    assert_equal 2, RefereeObservation.last.ratings.sole.position
  end

  # Abgleich Bericht gegen bewertete Personen: Lizenznummer und Name tragen je
  # fuer sich. Fiele einer der beiden Wege weg, stuende ein bewerteter Schiri
  # zusaetzlich im Hinweis.
  test 'umbenannter Schiri wird ueber die Lizenznummer zugeordnet' do
    @game.update!(referee1_string: "#{@referee1.lizenznummer} Schiri-Neu, Anna",
                  referee2_string: "#{@referee2.lizenznummer} Pfiff, Bo")
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_empty entry['unrated_referee_names']
  end

  test 'Eintrag ohne passende Lizenznummer wird ueber den Namen zugeordnet' do
    @game.update!(referee1_string: '0 schiri,  anna ',
                  referee2_string: '999999 Pfiff, Bo')
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_empty entry['unrated_referee_names']
  end

  test 'Gast mit Datensatz und Freitext im Bericht steht nur einmal im Hinweis' do
    guest = create(:referee, vorname: 'Kamil', nachname: 'Gast', guest: true, lizenznummer: nil)
    @game.update!(referee2_string: '0 gast,  kamil', officiating_referee_ids: [@referee1.id, guest.id])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_equal ['Kamil Gast'], entry['unrated_referee_names']
  end

  test 'Freitext ohne bekanntes Profil fuehrt zur eigenen Meldung, leeres Gespann zur alten' do
    @game.update!(referee1_string: '0 Meier, Max', officiating_referee_ids: [])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_empty entry['referees']
    assert_equal ['Max Meier'], entry['unrated_referee_names']
    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :unprocessable_entity
    assert_equal RefereeObservationSubmission::NO_RATEABLE_REFEREES_ERROR, JSON.parse(response.body)['error']

    @game.update!(referee1_string: nil)
    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :unprocessable_entity
    assert_equal RefereeObservationSubmission::NO_REFEREES_ERROR, JSON.parse(response.body)['error']
  end

  # Nennt der Bericht nur Gaeste, loest Game#feedback_referees niemanden auf und
  # faellt auf die Ansetzung zurueck. Die angesetzten Schiris haben dann aber
  # nicht gepfiffen und duerfen nicht bewertet werden.
  test 'angesetzte Schiris ohne Eintrag im Bericht werden nicht bewertet' do
    @game.update!(referee1_string: '0 Gast, Gustav', referee2_string: '0 Gast, Gerda',
                  officiating_referee_ids: [0, 0],
                  nominated_referee_ids: [@referee1.id, @referee2.id])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_empty entry['referees']
    assert_equal ['Gustav Gast', 'Gerda Gast'], entry['unrated_referee_names']

    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :unprocessable_entity
    assert_equal RefereeObservationSubmission::NO_RATEABLE_REFEREES_ERROR, JSON.parse(response.body)['error']
  end

  test 'angesetzter Schiri, der im Bericht als Freitext steht, bleibt bewertbar auf seinem Slot' do
    @game.update!(referee1_string: '0 Gast, Gustav', referee2_string: '0 Pfiff, Bo',
                  officiating_referee_ids: [0, 0],
                  nominated_referee_ids: [@referee1.id, @referee2.id])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_equal([[@referee2.id, 2]], entry['referees'].map { |r| [r['referee_id'], r['position']] })
    assert_equal ['Gustav Gast'], entry['unrated_referee_names']
  end

  # '0 , ' ist ein gesetzter und wieder geleerter Platz, kein Schiri.
  test 'ohne Schiris im Bericht bleibt die Ansetzung massgeblich, auch bei geleerten Plaetzen' do
    @game.update!(referee1_string: '0 , ', referee2_string: '0 , ',
                  officiating_referee_ids: [], nominated_referee_ids: [@referee1.id, @referee2.id])
    login(@coach_user)

    get '/api/v2/referee/observations/games'
    entry = JSON.parse(response.body).find { |g| g['game_id'] == @game.id }
    assert_equal([@referee1.id, @referee2.id], entry['referees'].map { |r| r['referee_id'] })
  end

  test 'Konto ohne Schiedsrichterprofil bekommt 403' do
    login(create(:user, :admin))
    get '/api/v2/referee/observations'
    assert_response :forbidden
  end

  # Bearbeitung des eigenen Bogens (feedback#74)

  test 'Coach bearbeitet den eigenen Bogen, der Bogen traegt den Vermerk' do
    observation = submit_as_coach
    assert_nil observation.edited_at

    changed = payload
    changed[:final_comments] = 'Korrigiert: Laufwege im Gespann abstimmen.'
    changed[:pair_overall_rating] = 6
    changed[:ratings][1][:overall_rating] = 4
    patch "/api/v2/referee/observations/#{observation.id}", params: changed, as: :json
    assert_response :success

    observation.reload
    assert_equal 'Korrigiert: Laufwege im Gespann abstimmen.', observation.final_comments
    assert_equal 6, observation.pair_overall_rating
    assert_equal 4, observation.ratings.find { |r| r.referee_id == @referee2.id }.overall_rating
    assert_not_nil observation.edited_at
    assert_equal observation.edited_at.iso8601, JSON.parse(response.body)['edited_at']
    assert_equal 1, RefereeObservation.count
  end

  test 'beobachtete Person sieht den Vermerk' do
    observation = submit_as_coach
    changed = payload
    changed[:other_matters] = 'Nachtrag zur Halle.'
    patch "/api/v2/referee/observations/#{observation.id}", params: changed, as: :json
    assert_response :success

    login(referee_user(@referee1))
    get '/api/v2/referee/observations/received'
    entry = JSON.parse(response.body).first
    assert_equal 'Nachtrag zur Halle.', entry['other_matters']
    assert entry['edited_at'].present?
  end

  test 'Bearbeitung verschickt keine Mail an die beobachteten Schiedsrichter' do
    referee_user(@referee1)
    referee_user(@referee2)
    observation = submit_as_coach

    changed = payload
    changed[:final_comments] = 'Anders formuliert.'
    assert_no_difference 'ActionMailer::Base.deliveries.size' do
      perform_enqueued_jobs do
        patch "/api/v2/referee/observations/#{observation.id}", params: changed, as: :json
      end
    end
    assert_response :success
  end

  test 'unveraendert gespeicherter Bogen bekommt keinen Vermerk' do
    observation = submit_as_coach
    patch "/api/v2/referee/observations/#{observation.id}", params: payload, as: :json
    assert_response :success
    assert_nil observation.reload.edited_at
  end

  test 'unvollstaendige Bearbeitung wird abgewiesen und laesst den Bogen unveraendert' do
    observation = submit_as_coach
    broken = payload
    broken[:final_comments] = ''
    broken[:match_description] = 'Neu'
    patch "/api/v2/referee/observations/#{observation.id}", params: broken, as: :json
    assert_response :unprocessable_entity

    observation.reload
    assert_equal 'Kopf-an-Kopf-Spiel.', observation.match_description
    assert_nil observation.edited_at
  end

  test 'fehlende Noten einer bewerteten Person werden abgewiesen' do
    observation = submit_as_coach
    broken = payload
    broken[:ratings] = broken[:ratings].first(1)
    patch "/api/v2/referee/observations/#{observation.id}", params: broken, as: :json
    assert_response :unprocessable_entity
    assert_equal 3, observation.reload.ratings.find { |r| r.referee_id == @referee2.id }.overall_rating
  end

  test 'Bearbeitung fuegt keine neue bewertete Person hinzu' do
    login(@coach_user)
    single = payload
    single[:ratings] = single[:ratings].first(1)
    post '/api/v2/referee/observations', params: single, as: :json
    assert_response :created
    observation = RefereeObservation.last

    patch "/api/v2/referee/observations/#{observation.id}", params: payload, as: :json
    assert_response :success
    assert_equal [@referee1.id], observation.reload.ratings.map(&:referee_id)
  end

  test 'Bearbeitung bleibt ohne Frist und nach Ablauf der Qualifikation moeglich' do
    observation = submit_as_coach
    observation.update_columns(submitted_at: 2.years.ago)
    RefereeQualification.where(referee: @coach).update_all(valid_until: 1.day.ago.to_date)

    changed = payload
    changed[:final_comments] = 'Spaete Korrektur.'
    patch "/api/v2/referee/observations/#{observation.id}", params: changed, as: :json
    assert_response :success
    assert_equal 'Spaete Korrektur.', observation.reload.final_comments
  end

  test 'nur der abgebende Coach darf bearbeiten' do
    observation = submit_as_coach
    other_coach = create(:referee)
    RefereeQualification.create!(referee: other_coach, referee_qualification_type: @b_type,
                                 valid_until: 1.year.from_now.to_date)
    changed = payload
    changed[:final_comments] = 'Fremd ueberschrieben.'

    [referee_user(other_coach), referee_user(@referee1)].each do |user|
      login(user)
      patch "/api/v2/referee/observations/#{observation.id}", params: changed, as: :json
      assert_response :forbidden
    end
    assert_equal 'Kommunikation im Gespann ausbauen.', observation.reload.final_comments
  end

  test 'unbekannter Bogen liefert 404' do
    login(@coach_user)
    patch '/api/v2/referee/observations/0', params: payload, as: :json
    assert_response :not_found
  end

  private

  def submit_as_coach
    login(@coach_user)
    post '/api/v2/referee/observations', params: payload, as: :json
    assert_response :created
    RefereeObservation.find(JSON.parse(response.body)['id'])
  end

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
