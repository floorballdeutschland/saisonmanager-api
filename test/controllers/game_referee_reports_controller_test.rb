require 'test_helper'

class GameRefereeReportsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @sa = StateAssociation.create!(name: 'LV', vsk_email: 'vsk@example.de', sbk_email: 'sbk@example.de',
                                   report_form_email_enabled: true)
    @go = GameOperation.create!(name: 'GO', short_name: 'GO', state_association_id: @sa.id)
    @league = League.create!(game_operation: @go, name: 'Liga', season_id: '18', table_modus: 'classic')
    @club = Club.create!(state_association_id: @sa.id)
    @arena = Arena.create!(name: 'Halle', city: 'Stadt')
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-02-01')
    @home = Team.create!(league: @league, club: @club, name: 'H')
    @guest = Team.create!(league: @league, club: @club, name: 'G')
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest, forfait: 0,
                         overtime: false, legacy: false, events: [], players: { 'home' => [], 'guest' => [] })
    @referee = Referee.create!(vorname: 'Ref', nachname: 'Eree', lizenznummer: 12_345)
    @user = User.create!(
      user_name: "refuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [],
      teams: [],
      referee_id: @referee.id
    )
    RefereeAssignment.create!(game: @game, referee1_id: @referee.id, status: 'published')
  end

  test 'aktivierter Workflow versendet Bericht per E-Mail an die VSK' do
    login(@user)
    assert_enqueued_emails 1 do
      upload_report
    end
    assert_response :created
  end

  test 'deaktivierter Workflow versendet keine E-Mail' do
    @sa.update!(report_form_email_enabled: false)
    login(@user)
    assert_no_enqueued_emails do
      upload_report
    end
    assert_response :created
  end

  test 'manueller Verfahrensvorschlag hat Vorrang und versendet keine E-Mail' do
    @sa.update!(manual_proceeding_creation: true)
    login(@user)
    assert_no_enqueued_emails do
      assert_difference -> { ProceedingProposal.count }, 1 do
        upload_report
      end
    end
    assert_response :created
  end

  private

  def upload_report
    post "/api/v2/games/#{@game.id}/referee_report",
         params: { file: fixture_file_upload('dokument.pdf', 'application/pdf') }
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
