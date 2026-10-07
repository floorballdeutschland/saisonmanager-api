require 'test_helper'

# Sichtbarkeit der Freitext-Spielinformationen des Ansetzers („Zusätzliche
# Spielinformationen") in „Meine Spieltage" – und die Sonderrolle des
# Schiedsrichtercoaches, der angesetzt ist, aber keine Spieltagsbestätigung
# abgibt.
class RefereeGameDayConfirmationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @state_association = create(:state_association)
    @state_association.checklist_items.create!(question: 'Halle rechtzeitig offen?')
    @game_operation = create(:game_operation, state_association_id: @state_association.id)
    @league = create(:league, game_operation: @game_operation)
    @game_day = create(:game_day, league: @league, date: (Date.today - 1).to_s)
    @game = create(:game, game_day: @game_day, start_time: '14:00')

    @referee = create(:referee)
    @partner = create(:referee)
    @coach = create(:referee)
  end

  test 'angesetztes Gespann sieht die Spielinformationen des Ansetzers' do
    publish_assignment(referee1: @referee, referee2: @partner, coach: @coach)
    @game.update!(referee_notes: 'Ansprechpartner am Eingang: Herr Meier')

    login(referee_user(@referee))
    get '/api/v2/referee/game_days'

    assert_response :success
    day = JSON.parse(response.body).find { |d| d['id'] == @game_day.id }
    assert_equal 'Ansprechpartner am Eingang: Herr Meier', day['games'].first['referee_notes']
    assert_equal false, day['coach_only']
    assert_equal true, day['checklist_required']
  end

  test 'Coach sieht die Spielinformationen, muss aber nichts bestätigen' do
    publish_assignment(referee1: @referee, referee2: @partner, coach: @coach)
    @game.update!(referee_notes: 'Beobachtung im ersten Drittel von der Bank aus')

    login(referee_user(@coach))
    get '/api/v2/referee/game_days'

    assert_response :success
    day = JSON.parse(response.body).find { |d| d['id'] == @game_day.id }
    assert_not_nil day, 'Coach sieht den Spieltag, auf den er angesetzt ist'
    assert_equal 'Beobachtung im ersten Drittel von der Bank aus', day['games'].first['referee_notes']
    assert_equal true, day['coach_only']
    assert_equal false, day['checklist_required']
    assert_nil day['partner_confirmed_at']
  end

  test 'Coach darf den Spieltag nicht bestätigen' do
    publish_assignment(referee1: @referee, referee2: @partner, coach: @coach)

    login(referee_user(@coach))
    post "/api/v2/referee/game_days/#{@game_day.id}/confirm", params: { properly_conducted: true }

    assert_response :forbidden
    assert_equal 0, GameDayRefereeConfirmation.count
  end

  test 'nicht veröffentlichte Ansetzung liefert weder Spieltag noch Notiz' do
    RefereeAssignment.create!(game: @game, referee1: @referee, referee2: @partner, status: 'tentative')
    @game.update!(referee_notes: 'Noch nicht zugestellt')

    login(referee_user(@referee))
    get '/api/v2/referee/game_days'

    assert_response :success
    assert_empty JSON.parse(response.body)
  end

  test 'fremder Schiedsrichter sieht die Spielinformationen nicht' do
    publish_assignment(referee1: @partner, referee2: create(:referee))
    @game.update!(referee_notes: 'Nur für das angesetzte Gespann')
    other_game_day = create(:game_day, league: @league, date: (Date.today - 1).to_s)
    other_game = create(:game, game_day: other_game_day, start_time: '16:00')
    RefereeAssignment.create!(game: other_game, referee1: @referee, status: 'published')

    login(referee_user(@referee))
    get '/api/v2/referee/game_days'

    assert_response :success
    days = JSON.parse(response.body)
    assert_equal [other_game_day.id], days.pluck('id')
    assert_nil days.first['games'].first['referee_notes']
  end

  test 'Mit-Angesetzte erscheinen mit Namen, Kontaktdaten nur bei eigener Freigabe' do
    @partner.update!(vorname: 'Paula', nachname: 'Partner', email: 'paula@example.com',
                     telefonnummer: '0170 1234567', share_contact_with_officials: true)
    @coach.update!(vorname: 'Carl', nachname: 'Coach', email: 'carl@example.com',
                   telefonnummer: '0171 7654321', share_contact_with_officials: nil)
    @referee.update!(share_contact_with_officials: true)
    publish_assignment(referee1: @referee, referee2: @partner, coach: @coach)

    login(referee_user(@referee))
    get '/api/v2/referee/game_days'

    officials = officials_for(JSON.parse(response.body))
    assert_equal %w[referee2 coach], officials.pluck('role'), 'die eigene Person fehlt in der Liste'

    partner = officials.find { |o| o['role'] == 'referee2' }
    assert_equal 'Paula Partner', partner['name']
    assert_equal true, partner['contact_shared']
    assert_equal '0170 1234567', partner['telefonnummer']
    assert_equal 'paula@example.com', partner['email']

    coach = officials.find { |o| o['role'] == 'coach' }
    assert_equal 'Carl Coach', coach['name']
    assert_equal false, coach['contact_shared'], 'nie gefragt zaehlt als Nein'
    assert_nil coach['telefonnummer']
    assert_nil coach['email']
  end

  test 'Coach sieht die Kontaktdaten des Gespanns, eine Ablehnung bleibt verborgen' do
    @referee.update!(email: 'schiri@example.com', telefonnummer: '0170 1', share_contact_with_officials: true)
    @partner.update!(email: 'partner@example.com', telefonnummer: '0170 2', share_contact_with_officials: false)
    @coach.update!(share_contact_with_officials: true)
    publish_assignment(referee1: @referee, referee2: @partner, coach: @coach)

    login(referee_user(@coach))
    get '/api/v2/referee/game_days'

    officials = officials_for(JSON.parse(response.body))
    assert_equal %w[referee1 referee2], officials.pluck('role')
    assert_equal 'schiri@example.com', officials.first['email']
    assert_equal '0170 1', officials.first['telefonnummer']
    assert_equal false, officials.last['contact_shared']
    assert_nil officials.last['email']
    assert_nil officials.last['telefonnummer']
  end

  test 'Kontaktdaten verschwinden nach dem Tag nach dem Spieltag, die Namen bleiben' do
    @partner.update!(email: 'partner@example.com', telefonnummer: '0170 2', share_contact_with_officials: true)
    @referee.update!(share_contact_with_officials: true)
    @game_day.update!(date: (Date.today - 2).to_s)
    publish_assignment(referee1: @referee, referee2: @partner)

    login(referee_user(@referee))
    get '/api/v2/referee/game_days'

    partner = officials_for(JSON.parse(response.body)).first
    assert_equal true, partner['contact_shared']
    assert_nil partner['email']
    assert_nil partner['telefonnummer']
    assert_not_nil partner['name']
  end

  test 'kommender Spieltag liefert die freigegebenen Kontaktdaten' do
    @partner.update!(email: 'partner@example.com', share_contact_with_officials: true)
    @referee.update!(share_contact_with_officials: true)
    @game_day.update!(date: (Date.today + 5).to_s)
    publish_assignment(referee1: @referee, referee2: @partner)

    login(referee_user(@referee))
    get '/api/v2/referee/game_days'

    assert_equal 'partner@example.com', officials_for(JSON.parse(response.body)).first['email']
  end

  [nil, false].each do |own|
    test "wer selbst nicht teilt (#{own.inspect}), sieht auch fremde Kontaktdaten nicht" do
      @referee.update!(share_contact_with_officials: own)
      @partner.update!(email: 'partner@example.com', telefonnummer: '0170 2', share_contact_with_officials: true)
      publish_assignment(referee1: @referee, referee2: @partner)

      login(referee_user(@referee))
      get '/api/v2/referee/game_days'

      partner = officials_for(JSON.parse(response.body)).first
      assert_equal true, partner['contact_shared'], 'die Freigabe selbst bleibt sichtbar'
      assert_nil partner['email']
      assert_nil partner['telefonnummer']
    end
  end

  private

  def officials_for(days)
    days.find { |d| d['id'] == @game_day.id }['games'].first['officials']
  end

  def publish_assignment(referee1:, referee2: nil, coach: nil)
    RefereeAssignment.create!(
      game: @game, referee1: referee1, referee2: referee2, coach: coach,
      status: 'published', published_at: Time.current
    )
  end

  def referee_user(referee)
    create(:user, permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }], referee: referee)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
