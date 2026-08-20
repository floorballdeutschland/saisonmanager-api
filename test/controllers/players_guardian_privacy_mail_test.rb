require 'test_helper'

# Datenschutz-Info an die gesetzliche Vertretung (Art. 13 DSGVO) beim
# Lizenzantrag. Die im Formular erfasste Adresse wurde bis 1.81.0 nur an der
# Lizenz vermerkt, verschickt wurde nichts.
class PlayersGuardianPrivacyMailTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @game_operation = create(:game_operation, state_association_id: @sa.id)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @vm = create(:user, :vm, club_id: @club.id)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def minor_player(**attrs)
    create(:player,
           birthdate: 15.years.ago.to_date.to_s,
           clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.day.ago.iso8601 }],
           **attrs)
  end

  test 'Lizenzantrag mit Adresse der gesetzlichen Vertretung verschickt die Datenschutz-Info' do
    @league.update!(parental_consent_required: true)
    minor = minor_player
    login_as(@vm)

    assert_enqueued_emails 1 do
      post "/api/v2/user/players/#{minor.id}/request_license",
           params: { team_id: @team.id, guardian_email: 'eltern@example.de',
                     minor_consent_at: Time.current.iso8601 },
           as: :json
      assert_response :ok
    end

    perform_enqueued_jobs
    mail = ActionMailer::Base.deliveries.last
    assert_equal ['eltern@example.de'], mail.to
    assert_match(/Datenschutzinformation/, mail.subject)
    assert_equal 'eltern@example.de', minor.reload.licenses.first['guardian_email']
  end

  test 'Lizenzantrag ohne Adresse verschickt keine Datenschutz-Info' do
    @league.update!(parental_consent_required: true)
    minor = minor_player
    login_as(@vm)

    assert_enqueued_emails 0 do
      post "/api/v2/user/players/#{minor.id}/request_license",
           params: { team_id: @team.id }, as: :json
      assert_response :ok
    end
  end

  # Die Zustimmungspflicht kann aus einer Pokal-Liga eines anderen Verbands
  # kommen. Dann muss die Mail diese Liga nennen und an deren SBK antworten,
  # nicht an die der Hauptliga, die gar keine Zustimmung verlangt.
  test 'Datenschutz-Info nennt die Liga, die die Zustimmung verlangt' do
    pokal_sa = create(:state_association, sbk_email: 'pokal-sbk@example.de')
    pokal_go = create(:game_operation, state_association_id: pokal_sa.id)
    pokal = create(:league, :current_season, game_operation: pokal_go, name: 'FD-Pokal',
                                             parental_consent_required: true)
    @team.update!(cup_leagues: [pokal.id])
    minor = minor_player
    login_as(@vm)

    assert_enqueued_emails 1 do
      post "/api/v2/user/players/#{minor.id}/request_license",
           params: { team_id: @team.id, guardian_email: 'eltern@example.de' }, as: :json
      assert_response :ok
    end

    perform_enqueued_jobs
    mail = ActionMailer::Base.deliveries.last
    assert_includes mail.body.decoded, 'FD-Pokal'
    assert_equal ['pokal-sbk@example.de'], mail.reply_to
  end

  # Verlangen Hauptliga und Pokal-Liga die Zustimmung, gehört die Mail zur
  # Hauptliga. Vorher entschied das die Sortierung des default_scope von League,
  # und eine Regionalliga-Lizenz konnte eine Mail über den FD-Pokal auslösen,
  # beantwortbar nur bei einem Verband, mit dem der Verein nichts zu tun hat.
  test 'bei zwei zustimmungspflichtigen Ligen nennt die Mail die Hauptliga' do
    # Die Pokal-Liga bekommt den kleineren Spielbetrieb, damit der default_scope
    # von League (season_id, game_operation_id, order_key) sie vor die Hauptliga
    # stellt. Genau diese Reihenfolge entschied vorher, welche Liga die Mail nennt.
    pokal_sa = create(:state_association, sbk_email: 'pokal-sbk@example.de')
    pokal_go = create(:game_operation, state_association_id: pokal_sa.id)
    pokal = create(:league, :current_season, game_operation: pokal_go, name: 'FD-Pokal',
                                             parental_consent_required: true)
    # Eigener Landesverband mit demselben Postfach: Ein Verband hat hoechstens
    # einen Spielbetrieb, und an @sa haengt schon der aus dem setup. Fuer die
    # Zusicherung unten zaehlt allein das reply_to.
    haupt_go = create(:game_operation,
                      state_association: create(:state_association, sbk_email: 'sbk@example.de'))
    @league.update!(name: 'Regionalliga Bayern', game_operation: haupt_go,
                    parental_consent_required: true)
    @team.update!(cup_leagues: [pokal.id])
    assert_equal pokal.id, @team.reload.leagues.first.id,
                 'Vorbedingung: der default_scope stellt die Pokal-Liga nach vorn'
    minor = minor_player
    login_as(@vm)

    post "/api/v2/user/players/#{minor.id}/request_license",
         params: { team_id: @team.id, guardian_email: 'eltern@example.de' }, as: :json
    assert_response :ok

    perform_enqueued_jobs
    mail = ActionMailer::Base.deliveries.last
    assert_includes mail.body.decoded, 'Regionalliga Bayern'
    assert_not_includes mail.body.decoded, 'FD-Pokal'
    assert_equal ['sbk@example.de'], mail.reply_to
  end

  # Ohne Liga mit Zustimmungspflicht fragt das Antragsformular die Adresse gar
  # nicht ab; ein trotzdem mitgeschickter Wert darf keine Mail auslösen.
  test 'ohne Zustimmungspflicht wird keine Datenschutz-Info verschickt' do
    minor = minor_player
    login_as(@vm)

    assert_enqueued_emails 0 do
      post "/api/v2/user/players/#{minor.id}/request_license",
           params: { team_id: @team.id, guardian_email: 'eltern@example.de' }, as: :json
      assert_response :ok
    end
    assert_equal 'eltern@example.de', minor.reload.licenses.first['guardian_email'],
                 'die Angabe bleibt trotzdem an der Lizenz dokumentiert'
  end

  # Ohne gespeicherte Lizenz keine Mail: Die Eltern sollen nicht über eine
  # Beantragung informiert werden, die die Transaktion gerade zurückgerollt hat.
  test 'abgelehnter Doppelantrag verschickt keine Datenschutz-Info' do
    @league.update!(parental_consent_required: true)
    minor = minor_player(with_licenses: [{ team: @team, status: License::REQUESTED }])
    login_as(@vm)

    assert_enqueued_emails 0 do
      post "/api/v2/user/players/#{minor.id}/request_license",
           params: { team_id: @team.id, guardian_email: 'eltern@example.de' }, as: :json
      assert_response :unprocessable_entity
    end
  end
end
