require 'test_helper'

# Protest mit Protestparteien: Nach dem Haken wählt die Spielleitung, wer
# protestiert. Beim Abschluss bekommt jede Partei außer „Andere" einen
# Upload-Link (GameProtestInviter).
class GamesProtestPartiesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting, current_season_id: '18')
    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, :current_season, game_operation: @go, league_modus: 'league',
                                               age_group: 'Herren', field_size: 'GF')
    @host = create(:club, contact_email: 'heim@example.de')
    @guest_club = create(:club, contact_email: 'gast@example.de')
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @host,
                                number: 1, date: Date.current.to_s)
    @home = create(:team, league: @league, club: @host)
    @guest = create(:team, league: @league, club: @guest_club)
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                         started: true, ended: true, forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] },
                         game_status: 'aftergame', **all_signatures,
                         referee1_string: '12345 Eree, Ref', referee2_string: '23456 Zwei, Ref')
    @r1 = create(:referee, email: 'ref1@example.de')
    @r2 = create(:referee, email: nil)
    RefereeAssignment.create!(game: @game, referee1_id: @r1.id, referee2_id: @r2.id, status: 'published')
    @vm = create(:user, :vm, club_id: @host.id)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def save_flags(attrs)
    post "/api/v2/user/games/#{@game.id}/set_flag", params: { game: attrs }, as: :json
  end

  def close_match_record
    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'match_record_closed' }, as: :json
  end

  test 'Ausrichter steht nur getrennt zur Wahl, wenn er nicht das Heimteam stellt' do
    assert_equal %w[home guest referees other], @game.available_protest_parties
    assert_match(%r{Heimteam / Ausrichter}, @game.protest_party_label('home'))

    other_host = create(:club, name: 'Hallenverein')
    @game_day.update!(club: other_host)
    @game.reload
    assert_equal %w[host home guest referees other], @game.available_protest_parties
    assert_equal 'Ausrichter (Hallenverein)', @game.protest_party_label('host')
  end

  test 'die Auswahl wird gespeichert und mit dem Protest-Haken wieder geleert' do
    login(@vm)
    save_flags(protest: true, protest_parties: %w[referees guest guest])
    assert_response :success
    assert_equal %w[guest referees], @game.reload.protest_parties

    save_flags(protest: false)
    assert_response :success
    assert_equal [], @game.reload.protest_parties
  end

  test 'eine nicht wählbare Partei wird abgelehnt' do
    login(@vm)
    save_flags(protest: true, protest_parties: %w[host])
    assert_response :unprocessable_entity
    assert_equal [], @game.reload.protest_parties
  end

  test 'die Zusatzfelder liefern Auswahl und Optionen, die öffentliche Spielseite nicht' do
    @game.update!(protest: true, protest_parties: %w[guest])
    login(@vm)

    get "/api/v2/user/games/#{@game.id}/additional_fields"
    body = response.parsed_body
    assert_equal %w[guest], body['protest_parties']
    assert_equal %w[home guest referees other], body['protest_party_options'].pluck('key')

    assert_not_includes @game.as_json.keys, 'protest_parties'
  end

  test 'Protest ohne Partei verhindert den Abschluss für den Verein' do
    @game.update!(protest: true)
    login(@vm)

    close_match_record

    assert_response :unprocessable_entity
    assert_includes response.parsed_body['message'], 'keine Protestpartei ausgewählt'
    assert_equal 'aftergame', @game.reload.game_status
  end

  test 'die SBK schließt auch ohne Partei ab' do
    @game.update!(protest: true)
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    close_match_record

    assert_response :success
  end

  test 'beim Abschluss bekommt jede Partei außer Andere einen Link' do
    @game.update!(protest: true, protest_parties: %w[home guest referees other])
    login(@vm)

    assert_enqueued_emails 3 do
      close_match_record
    end
    assert_response :success

    protests = @game.reload.game_protests.index_by(&:party)
    assert_equal %w[guest home referees], protests.keys.sort
    assert_includes protests['home'].recipients, 'heim@example.de'
    assert_equal ['gast@example.de'], protests['guest'].recipients
    # Schiedsrichter 2 ohne Adresse: ein Link für beide, an die eine Adresse.
    assert_equal ['ref1@example.de'], protests['referees'].recipients
    assert(protests.values.all? { |p| p.invited_at.present? && p.token_digest.present? })
  end

  test 'die Mail enthält den persönlichen Upload-Link' do
    @game.update!(protest: true, protest_parties: %w[guest])
    login(@vm)

    perform_enqueued_jobs { close_match_record }

    mail = ActionMailer::Base.deliveries.find { |m| m.subject.include?('Protestformular hochladen') }
    assert mail
    assert_equal ['gast@example.de'], mail.to
    assert_equal ['sbk@example.de'], mail.reply_to
    body = (mail.html_part || mail).decoded
    token = body[%r{/protest/([A-Za-z0-9_-]+)}, 1]
    assert token
    assert_equal @game.game_protests.first, GameProtest.find_by_token(token)
    assert_includes body, 'Gastteam'
  end

  test 'ohne Adresse wird der Protest trotzdem angelegt, aber nichts verschickt' do
    @r1.update!(email: nil)
    @game.update!(protest: true, protest_parties: %w[referees])
    login(@vm)

    assert_no_enqueued_emails { close_match_record }

    assert_equal [], @game.reload.game_protests.first.recipients
  end

  test 'ein erneuter Abschluss verschickt nichts doppelt' do
    @game.update!(protest: true, protest_parties: %w[guest])
    login(create(:user, :admin))
    close_match_record
    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'aftergame' }, as: :json

    assert_no_enqueued_emails { close_match_record }
    assert_equal 1, @game.reload.game_protests.count
  end

  test 'nach dem Abschluss ändert der Verein den Protest nicht mehr' do
    @game.update!(game_status: 'match_record_closed')
    login(@vm)

    save_flags(protest: true, protest_parties: %w[guest])

    assert_response :unprocessable_entity
    assert_includes response.parsed_body['message'], 'nur die SBK'
    assert_not @game.reload.protest?
  end

  test 'ergänzt die SBK nach dem Abschluss eine Partei, geht deren Link sofort raus' do
    @game.update!(game_status: 'match_record_closed', protest: true, protest_parties: %w[other])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    assert_enqueued_emails 1 do
      save_flags(protest: true, protest_parties: %w[guest other])
    end
    assert_response :success
    assert_equal %w[guest], @game.reload.game_protests.pluck(:party)
  end

  test 'Andere allein löst nichts aus' do
    @game.update!(protest: true, protest_parties: %w[other])
    login(@vm)

    assert_no_enqueued_emails { close_match_record }

    assert_response :success
    assert_equal 0, @game.reload.game_protests.count
  end
end
