require 'test_helper'

# Coach-Ansetzung im reduzierten Modus: Verbände, die Schiedsrichter:innen nicht
# personenscharf ansetzen, lassen die RSK trotzdem Schiedsrichtercoaches
# ansetzen (Schalter coach_assignment_enabled am Landesverband).
module Admin
  class RefereeAssignmentClubCoachTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      create(:setting)
      @sa = create(:state_association, referee_assignment_external_enabled: true,
                                       coach_assignment_enabled: true)
      @go = create(:game_operation, state_association_id: @sa.id)
      @league = create(:league, game_operation: @go)
      @date = Date.today + 30
      @game_day = create(:game_day, league: @league, date: @date.to_s)
      @game = create(:game, game_day: @game_day, game_status: 'pregame')
      @rsk = create(:user, :rsk_scoped, game_operation_id: @go.id)
      @club = create(:club, state_association_id: @sa.id)
      create(:team, league: @league, club: @club)

      @b_type = RefereeQualificationType.create!(name: 'B-Coach', short_name: 'B', active: true)
      @coach = qualified_coach('Cem', 'Coach', 'cem@example.org')
    end

    test 'Spieleliste meldet Coach-Ansetzung je Spiel' do
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'

      entry = JSON.parse(response.body).find { |g| g['id'] == @game.id }
      assert_equal true, entry['coach_assignable']
    end

    test 'ohne Coach-Schalter kein Coach-Feld und kein Zugriff' do
      @sa.update!(coach_assignment_enabled: false)
      login(@rsk)

      get '/api/v2/admin/referee_assignments/games'
      entry = JSON.parse(response.body).find { |g| g['id'] == @game.id }
      assert_equal false, entry['coach_assignable']

      patch "/api/v2/admin/referee_assignments/games/#{@game.id}/club_coach",
            params: { coach_id: @coach.id }
      assert_response :forbidden
      assert_nil @game.reload.referee_assignment
    end

    # Der Schalter ist eine Unteroption des reduzierten Modus. Steht der Verband
    # auf der Personenebene, setzt dort die Ansetzer-Rolle an.
    test 'Coach-Schalter wirkt nicht auf der Personenebene' do
      @sa.update_columns(referee_assignment_enabled: true)

      assert_not @sa.reload.club_level_coach_assignment_active?
    end

    test 'Coach-Liste zeigt alle qualifizierten Coaches des Verbands, Verfuegbarkeit nur als Hinweis' do
      mit_termin = qualified_coach('Ada', 'Arm', nil)
      RefereeAvailability.create!(referee: mit_termin, date: @date)
      abgelaufen = create(:referee, club_id: @club.id)
      RefereeQualification.create!(referee: abgelaufen, referee_qualification_type: @b_type,
                                   valid_until: @date - 1)
      fremder_verband = create(:referee, club_id: create(:club, state_association_id: create(:state_association).id).id)
      RefereeQualification.create!(referee: fremder_verband, referee_qualification_type: @b_type,
                                   valid_until: @date + 365)
      login(@rsk)

      get '/api/v2/admin/referee_assignments/club_coaches', params: { game_id: @game.id }

      assert_response :success
      rows = JSON.parse(response.body).index_by { |r| r['id'] }
      assert_equal [mit_termin.id, @coach.id].sort, rows.keys.sort
      assert_equal true, rows[mit_termin.id]['available']
      assert_equal false, rows[@coach.id]['available']
    end

    test 'Coach ansetzen gilt sofort und schickt die Ansetzungsmail' do
      login(@rsk)

      assert_enqueued_email_with RefereeMailer, :published_coach_notification,
                                 args: ->(args) { args.first == @coach } do
        patch "/api/v2/admin/referee_assignments/games/#{@game.id}/club_coach",
              params: { coach_id: @coach.id }
      end

      assert_response :success
      assignment = @game.reload.referee_assignment
      assert_equal @coach.id, assignment.coach_id
      # Ohne „published" griffe die Erinnerung zum Anpfiff nicht.
      assert_equal 'published', assignment.status
      assert_nil assignment.club_id
      assert_equal @coach.id, JSON.parse(response.body)['coach_id']
    end

    test 'Coach tauschen benachrichtigt den alten und den neuen' do
      neu = qualified_coach('Dana', 'Neu', 'dana@example.org')
      RefereeAssignment.create!(game: @game, coach: @coach, status: 'published',
                                observation_reminder_sent_at: Time.current)
      login(@rsk)

      assert_enqueued_emails 2 do
        patch "/api/v2/admin/referee_assignments/games/#{@game.id}/club_coach",
              params: { coach_id: neu.id }
      end

      assignment = @game.reload.referee_assignment
      assert_equal neu.id, assignment.coach_id
      # Die Marke galt dem alten Coach.
      assert_nil assignment.observation_reminder_sent_at
    end

    test 'Coach entfernen behaelt die Vereins-Ansetzung' do
      RefereeAssignment.create!(game: @game, club: @club, coach: @coach, status: 'published')
      login(@rsk)

      assert_enqueued_email_with RefereeMailer, :updated_assignment_notification,
                                 args: ->(args) { args.first == @coach } do
        patch "/api/v2/admin/referee_assignments/games/#{@game.id}/club_coach",
              params: { coach_id: '' }
      end

      assignment = @game.reload.referee_assignment
      assert_equal @club.id, assignment.club_id
      assert_nil assignment.coach_id
    end

    test 'Coach entfernen ohne Verein raeumt den leeren Datensatz weg' do
      RefereeAssignment.create!(game: @game, coach: @coach, status: 'published')
      login(@rsk)

      patch "/api/v2/admin/referee_assignments/games/#{@game.id}/club_coach",
            params: { coach_id: '' }

      assert_response :success
      assert_nil @game.reload.referee_assignment
    end

    # Bis hierhin löschte ein Freitext die ganze Ansetzung. Mit Coach hätte das
    # den angesetzten Coach kommentarlos aus dem Spiel geworfen.
    test 'Freitext behaelt den angesetzten Coach' do
      RefereeAssignment.create!(game: @game, club: @club, coach: @coach, status: 'published')
      login(@rsk)

      patch "/api/v2/admin/referee_assignments/games/#{@game.id}/club_assignment",
            params: { nominated_referee_string: 'Müller / Schmidt' }

      assert_response :success
      assignment = @game.reload.referee_assignment
      assert_equal @coach.id, assignment.coach_id
      assert_nil assignment.club_id
      assert_equal 'Müller / Schmidt', @game.nominated_referee_string
    end

    test 'Coach ohne Qualifikation wird abgelehnt' do
      ohne = create(:referee, club_id: @club.id)
      login(@rsk)

      patch "/api/v2/admin/referee_assignments/games/#{@game.id}/club_coach",
            params: { coach_id: ohne.id }

      assert_response :not_found
      assert_nil @game.reload.referee_assignment
    end

    test 'personenscharf markiertes Spiel bleibt gesperrt' do
      @game.update!(person_level_assignment: true)
      login(@rsk)

      patch "/api/v2/admin/referee_assignments/games/#{@game.id}/club_coach",
            params: { coach_id: @coach.id }

      assert_response :unprocessable_entity
    end

    test 'Ansetzer-Endpunkt fuer Coaches bleibt der RSK verschlossen' do
      login(@rsk)

      get '/api/v2/admin/referee_assignments/available_coaches', params: { date: @date.to_s }

      assert_response :forbidden
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def qualified_coach(vorname, nachname, email)
      coach = create(:referee, vorname:, nachname:, email:, club_id: @club.id)
      RefereeQualification.create!(referee: coach, referee_qualification_type: @b_type,
                                   valid_until: @date + 365)
      coach
    end
  end
end
