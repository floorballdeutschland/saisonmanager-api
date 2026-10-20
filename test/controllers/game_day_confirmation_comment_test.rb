require 'test_helper'

# Anmerkung zum Einspruch gegen den Spieltagsbericht. Gastmannschaft und
# Schiedsrichter konnten bisher nur einzelne Punkte verneinen, was genau
# schiefgelaufen war, musste die SBK nachfragen. Der Freitext ist freiwillig,
# gehört nur zum Einspruch und landet in der Mail an die SBK.
#
# Testtexte bewusst ohne Umlaute, damit die quoted-printable-Kodierung des
# Mail-Bodys die Suche nicht zerlegt.
class GameDayConfirmationCommentTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association, sbk_email: 'sbk@example.de')
    @item = @sa.checklist_items.create!(question: 'Halle rechtzeitig offen?', position: 1)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @ausrichter = create(:club, state_association_id: @sa.id)
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @ausrichter,
                                number: 1, date: Date.yesterday.to_s)
    @gast = create(:team, league: @league, club: create(:club, state_association_id: @sa.id))
    @game = Game.create!(game_day: @game_day, home_team: create(:team, league: @league, club: @ausrichter),
                         guest_team: @gast, game_number: '7', start_time: '14:00', forfait: 0,
                         events: [], players: { 'home' => [], 'guest' => [] })
    @tm = create(:user, :tm, team_id: @gast.id)
    @referee = create(:referee)
    RefereeAssignment.create!(game: @game, referee1: @referee, status: 'published', published_at: Time.current)
  end

  test 'Gastmannschaft gibt eine Anmerkung mit, sie steht in der Mail an die SBK' do
    login(@tm)
    perform_enqueued_jobs do
      team_veto(comment: "  Halle war um 13 Uhr noch zu.\nKein Ansprechpartner <b>vor Ort</b>.  ")
    end

    assert_response :created
    confirmation = GameDayTeamConfirmation.sole
    assert_equal "Halle war um 13 Uhr noch zu.\nKein Ansprechpartner <b>vor Ort</b>.", confirmation.comment
    assert_equal confirmation.comment, JSON.parse(response.body)['comment']

    body = sbk_mail.html_part&.body&.decoded || sbk_mail.body.decoded
    assert_includes body, 'Halle war um 13 Uhr noch zu.'
    assert_includes body, '&lt;b&gt;vor Ort&lt;/b&gt;', 'Freitext muss in der Mail escapet sein'
    assert_not_includes body, '<b>vor Ort</b>'
  end

  test 'Schiedsrichter gibt eine Anmerkung mit, sie steht in der Mail an die SBK' do
    login(referee_user(@referee))
    perform_enqueued_jobs do
      post "/api/v2/referee/game_days/#{@game_day.id}/confirm",
           params: { properly_conducted: false, answers: [{ item_id: @item.id, answer: false }],
                     comment: 'Zeitnehmer fehlte.' },
           as: :json
    end

    assert_response :created
    assert_equal 'Zeitnehmer fehlte.', GameDayRefereeConfirmation.sole.comment
    assert_includes sbk_mail.body.decoded, 'Zeitnehmer fehlte.'

    get '/api/v2/referee/game_days'
    day = JSON.parse(response.body).find { |d| d['id'] == @game_day.id }
    assert_equal 'Zeitnehmer fehlte.', day['my_comment']
  end

  test 'eine zu lange Anmerkung wird abgewiesen und nichts gespeichert' do
    login(@tm)
    team_veto(comment: 'x' * (GameDayConfirmationComment::COMMENT_MAX_LENGTH + 1))

    assert_response :unprocessable_entity
    assert_match(/höchstens 2000 Zeichen/, JSON.parse(response.body)['error'])
    assert_equal 0, GameDayTeamConfirmation.count
  end

  test 'eine leere Anmerkung wird nil' do
    login(@tm)
    team_veto(comment: "   \n ")

    assert_response :created
    assert_nil GameDayTeamConfirmation.sole.comment
  end

  test 'bei einer Bestätigung als ordnungsgemäß wird kein Text gespeichert' do
    login(referee_user(@referee))
    post "/api/v2/referee/game_days/#{@game_day.id}/confirm",
         params: { properly_conducted: true, comment: 'Alles bestens' }, as: :json

    assert_response :created
    assert_nil GameDayRefereeConfirmation.sole.comment
  end

  test 'gespeicherte Vorlage kann die Anmerkung ueber {{comment}} einsetzen' do
    EmailTemplate.create!(mailer_class: 'GameDayMailer', action_name: 'team_checklist_veto',
                          body: 'Anmerkung: {{comment}}')

    body = GameDayMailer.team_checklist_veto(@game_day, @gast, [], @sa, comment: 'A & B').body.decoded

    assert_includes body, 'Anmerkung: A &amp; B'
    assert_not_includes body, '&amp;amp;'
  end

  private

  def team_veto(comment:)
    post "/api/v2/user/team_game_days/#{@game_day.id}/teams/#{@gast.id}/confirm",
         params: { properly_conducted: false, answers: [{ item_id: @item.id, answer: false }], comment: },
         as: :json
  end

  def sbk_mail
    ActionMailer::Base.deliveries.find { |m| m.to == ['sbk@example.de'] }.tap { |m| assert_not_nil m }
  end

  def referee_user(referee)
    create(:user, permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }], referee:)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
