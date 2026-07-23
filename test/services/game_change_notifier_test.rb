require 'test_helper'

class GameChangeNotifierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, contact_email: 'ausrichter@example.de')
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-03-01')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                         start_time: '14:30', forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })
    @referee = create(:referee, email: 'schiri@example.de')
    @coach = create(:referee, email: 'coach@example.de')
  end

  test 'veröffentlichte Ansetzung: Schiri, Coach und Ausrichter erhalten je eine Update-Mail' do
    RefereeAssignment.create!(game: @game, referee1_id: @referee.id, coach_id: @coach.id, status: 'published')

    # 1 Schiri + 1 Coach + 1 Ausrichter
    assert_enqueued_emails 3 do
      GameChangeNotifier.notify(@game.reload)
    end
  end

  test 'kein Versand ohne Ansetzung' do
    assert_no_enqueued_emails do
      GameChangeNotifier.notify(@game.reload)
    end
  end

  test 'kein Versand bei vorläufiger (nicht veröffentlichter) Ansetzung' do
    RefereeAssignment.create!(game: @game, referee1_id: @referee.id, status: 'tentative')

    assert_no_enqueued_emails do
      GameChangeNotifier.notify(@game.reload)
    end
  end

  test 'kein Versand bei Vereins-Ansetzung' do
    RefereeAssignment.create!(game: @game, club_id: @club.id, status: 'published')

    assert_no_enqueued_emails do
      GameChangeNotifier.notify(@game.reload)
    end
  end

  test 'kein Ausrichter-Versand ohne contact_email' do
    @club.update!(contact_email: nil)
    RefereeAssignment.create!(game: @game, referee1_id: @referee.id, status: 'published')

    # nur der Schiri, kein Ausrichter
    assert_enqueued_emails 1 do
      GameChangeNotifier.notify(@game.reload)
    end
  end

  test 'Schiri ohne E-Mail-Adresse wird übersprungen' do
    referee_without_email = create(:referee, email: nil)
    RefereeAssignment.create!(game: @game, referee1_id: @referee.id, referee2_id: referee_without_email.id,
                              status: 'published')

    # Schiri 1 + Ausrichter (Schiri 2 ohne E-Mail entfällt)
    assert_enqueued_emails 2 do
      GameChangeNotifier.notify(@game.reload)
    end
  end

  test 'Anpfiff steht im gerenderten Mailtext' do
    body = RefereeMailer.updated_assignment_notification(@referee, @game, 'Vor Nach', nil).body.encoded

    assert_includes body, '14:30'
  end
end
