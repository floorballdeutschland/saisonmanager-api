require 'test_helper'

# Lesende Sicht des Vereinsmanagers auf seine Vereinsschiris (vm/referees).
# Geprüft wird vor allem die Grenze: E-Mail und Konto-Badge ja, Geburtsdatum,
# Anschrift und Ansetzungsdaten nein, und nichts von fremden Vereinen.
class VmRefereesTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @club = create(:club)
    @referee = create(:referee, club_id: @club.id, email: 'schiri@example.org',
                                telefonnummer: '0170 1234567', kurzfristig_mobil: true,
                                strasse: 'Hauptstraße', plz: '12345', ort: 'Musterstadt')
    login(create(:user, :vm, club_id: @club.id))
  end

  test 'Liste zeigt E-Mail und Konto-Badge' do
    create(:user, referee_id: @referee.id)
    without_account = create(:referee, club_id: @club.id)

    get '/api/v2/vm/referees'

    assert_response :success
    by_id = response.parsed_body.index_by { |r| r['id'] }
    assert_equal 'schiri@example.org', by_id[@referee.id]['email']
    assert by_id[@referee.id]['has_user']
    assert_not by_id[without_account.id]['has_user']
  end

  test 'Liste und Detail ohne Ansetzungsdaten, Geburtsdatum und Anschrift' do
    get '/api/v2/vm/referees'
    entry = response.parsed_body.find { |r| r['id'] == @referee.id }

    get "/api/v2/vm/referees/#{@referee.id}"
    assert_response :success
    detail = response.parsed_body

    [entry, detail].each do |json|
      %w[telefonnummer kurzfristig_mobil geburtsdatum strasse hausnummer plz ort user_name user_id].each do |key|
        assert_not json.key?(key), "#{key} gehört nicht in die Vereinssicht"
      end
    end
    assert_equal 'schiri@example.org', detail['email']
  end

  test 'Detail eines fremden Vereinsschiris ist nicht erreichbar' do
    foreign = create(:referee, club_id: create(:club).id)

    get "/api/v2/vm/referees/#{foreign.id}"
    assert_response :not_found

    get "/api/v2/vm/referees/#{foreign.id}/games"
    assert_response :not_found
  end

  test 'Einsatzhistorie umfasst alle Saisons' do
    current = game_for(@referee, season_id: '18', date: '2026-10-01')
    previous = game_for(@referee, season_id: '17', date: '2025-10-01')
    game_for(create(:referee, club_id: @club.id), season_id: '18', date: '2026-10-02')

    get "/api/v2/vm/referees/#{@referee.id}/games"

    assert_response :success
    assert_equal([current.id, previous.id], response.parsed_body.map { |g| g['id'] })
  end

  test 'ohne Vereinsmanager-Rolle gesperrt' do
    login(create(:user))

    get "/api/v2/vm/referees/#{@referee.id}"

    assert_response :forbidden
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def game_for(referee, season_id:, date:)
    league = create(:league, season_id: season_id)
    create(:game, game_day: create(:game_day, league: league, date: date),
                  officiating_referee_ids: [referee.id])
  end
end
