require 'test_helper'

# Die Verfahrenseröffnung geht im Namen der SBK an die VSK. Wer sie entschieden
# hat, stand vorher nirgends in der Mail: Sie endete beim Hinweis auf den Anhang.
# Seit api#564 trägt sie die Unterschrift des Kontos, das den Vorschlag
# angenommen hat – dieselbe Person, die am Vorschlag als `decided_by_id` steht.
#
# Der automatische Weg (kein Verfahrensvorschlag, GameRefereeReportsController)
# bleibt unverändert ohne Grußformel: Dort drückt niemand einen Knopf.
class ProceedingProposalSignatureTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association, vsk_email: 'vsk@example.de', sbk_email: 'sbk@example.de',
                                     report_form_email_enabled: true, manual_proceeding_creation: true)
    @go = create(:game_operation, state_association: @sa)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 1, date: '2026-02-01')
    @game = Game.create!(game_day: @game_day,
                         home_team: create(:team, league: @league, club: @club),
                         guest_team: create(:team, league: @league, club: @club),
                         forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })
    @uploader = create(:user, :admin, first_name: 'Uli', last_name: 'Uploader')
    report = @game.build_game_referee_report(uploaded_by: @uploader)
    report.file.attach(io: StringIO.new('PDF'), filename: 'report.pdf', content_type: 'application/pdf')
    report.save!
    @proposal = ProceedingProposal.create!(game: @game, state_association: @sa, status: 'pending',
                                           created_by_id: @uploader.id)
  end

  test 'die Verfahrenseroeffnung traegt den Namen der entscheidenden Person' do
    entscheider = create(:user, :sbk_scoped, game_operation_id: @go.id, first_name: 'Sara', last_name: 'Schiedsrichterin')
    login(entscheider)

    body = html(eroeffnen)

    assert_includes body, 'Mit sportlichen Grüßen'
    assert_includes body, 'Sara Schiedsrichterin'
    assert_equal entscheider.id, @proposal.reload.decided_by_id
  end

  # Die Unterschrift ist die entscheidende Person, nicht die hochladende. Beide
  # stehen in der Mail, und sie sind selten dieselbe.
  test 'die Unterschrift ist nicht die hochladende Person' do
    entscheider = create(:user, :sbk_scoped, game_operation_id: @go.id, first_name: 'Sara', last_name: 'Schiedsrichterin')
    login(entscheider)

    body = html(eroeffnen)

    assert_includes body, 'Uli Uploader'
    assert_match(/Mit sportlichen Grüßen.*Sara Schiedsrichterin/m, body)
  end

  # Der automatische Weg kennt keine entscheidende Person. Ohne Namen bleibt die
  # Grußformel weg, statt eine leere Zeile zu unterschreiben.
  test 'ohne entscheidende Person bleibt die Grussformel weg' do
    mail = RefereeMailer.referee_report_to_vsk(
      'vsk@example.de', @uploader, @game, @game.game_referee_report,
      game_url: @game.url, checklist_answers: []
    )

    assert_not_includes html(mail), 'Mit sportlichen'
  end

  # `User#fullname` ist bei einem Konto ohne Namen ein einzelnes Leerzeichen und
  # damit truthy. Ohne Normalisierung stuende eine Grußformel mit leerer Zeile
  # darunter.
  test 'ein Konto ohne Namen unterschreibt nicht mit einer leeren Zeile' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id, first_name: nil, last_name: nil))

    assert_not_includes html(eroeffnen), 'Mit sportlichen'
  end

  private

  # Der HTML-Teil im Klartext. `body.encoded` liefert bei einer Mail mit Anhang
  # den ganzen MIME-Rumpf in quoted-printable, in dem „Grüßen" nicht mehr als
  # Wort steht.
  def html(mail)
    (mail.html_part || mail).decoded
  end

  def eroeffnen
    mail = nil
    perform_enqueued_jobs do
      assert_emails 1 do
        post "/api/v2/admin/proceeding_proposals/#{@proposal.id}/open"
        assert_response :success
      end
      mail = ActionMailer::Base.deliveries.last
    end
    mail
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
