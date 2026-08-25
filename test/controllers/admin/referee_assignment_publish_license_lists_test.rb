require 'test_helper'

# Beim Veröffentlichen einer Ansetzung reisen die Lizenzlisten normalerweise
# NICHT mit: Ihr Link gilt nur bis zum Tag nach dem Spiel, angesetzt wird aber
# oft Wochen vorher (vorher: 72 h ab Versand, also längst abgelaufen). Sie kommen
# im Wochenlauf kurz vor dem Spiel.
#
# Ausnahme: Liegt das Spiel schon im Fenster des nächsten Wochenlaufs, käme keine
# Mail mehr davor – dann gehen die Listen direkt mit der Ansetzungsmail raus.
module Admin
  class RefereeAssignmentPublishLicenseListsTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @league = create(:league, game_operation: create(:game_operation, :national))
      @referee = create(:referee, email: 'schiri@example.de')
      @coach = create(:referee, email: 'coach@example.de')
    end

    def publish_assignment_for(date)
      game_day = create(:game_day, league: @league, date: date.to_s)
      game = create(:game, game_day: game_day, start_time: '14:00',
                           home_team: create(:team, league: @league), guest_team: create(:team, league: @league))
      assignment = RefereeAssignment.create!(game: game, referee1: @referee, coach: @coach, status: 'tentative')

      login(@admin)
      perform_enqueued_jobs do
        post "/api/v2/admin/referee_assignments/#{assignment.id}/publish"
      end
      assert_response :success
      assignment.reload
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def html_bodies
      ActionMailer::Base.deliveries.map { |mail| mail.html_part ? mail.html_part.body.decoded : mail.body.decoded }
    end

    test 'Ansetzung weit vor dem Spiel: kein Lizenzlisten-Link, Hinweis auf die spaetere Mail' do
      assignment = publish_assignment_for(Date.current + 21)

      assert_equal 2, ActionMailer::Base.deliveries.size
      html_bodies.each do |body|
        assert_not_includes body, 'Lizenzlisten ansehen'
        assert_includes body, 'wenige Tage vor dem Spiel'
      end
      # Nicht markiert: Der Wochenlauf muss die Listen noch schicken.
      assert_nil assignment.license_lists_notified_at
    end

    test 'kurzfristige Ansetzung: Lizenzlisten liegen der Ansetzungsmail bei' do
      assignment = publish_assignment_for(Date.current + 2)

      assert_equal 2, ActionMailer::Base.deliveries.size
      html_bodies.each do |body|
        assert_includes body, 'Lizenzlisten ansehen'
        assert_includes body, '/lizenzliste?token='
      end
      # Markiert, damit der Wochenlauf dieselbe Post nicht wiederholt.
      assert_not_nil assignment.license_lists_notified_at
    end

    test 'nach einer kurzfristigen Ansetzung schickt der Wochenlauf nichts nach' do
      publish_assignment_for(Date.current + 2)
      ActionMailer::Base.deliveries.clear

      RefereeLicenseListNotifier.new.run

      assert_empty ActionMailer::Base.deliveries
    end

    # Wer nach dem Wochenlauf ins Gespann kommt, stünde sonst ohne Liste da: Die
    # Ansetzung gilt als benachrichtigt, obwohl die neue Person nichts bekam.
    test 'Umbesetzung kurz vor dem Spiel schickt dem neuen Schiri die Listen' do
      assignment = publish_assignment_for(Date.current + 2)
      assert_not_nil assignment.license_lists_notified_at
      nachgesetzt = create(:referee, email: 'neu@example.de')
      ActionMailer::Base.deliveries.clear

      login(@admin)
      perform_enqueued_jobs do
        patch "/api/v2/admin/referee_assignments/#{assignment.id}",
              params: { assignment: { referee1_id: nachgesetzt.id } }
      end
      assert_response :success

      lizenzmails = ActionMailer::Base.deliveries.select { |m| m.subject.start_with?('Lizenzlisten') }
      assert_includes lizenzmails.flat_map(&:to), 'neu@example.de'
    end

    # Weit vor dem Spiel gibt es nichts sofort, aber die Marke muss fallen, damit
    # der Wochenlauf die neue Besetzung erfasst.
    test 'Umbesetzung weit vor dem Spiel gibt die Ansetzung an den Wochenlauf zurueck' do
      assignment = publish_assignment_for(Date.current + 2)
      assert_not_nil assignment.license_lists_notified_at
      game_day = assignment.game.game_day
      game_day.update_column(:date, (Date.current + 21).to_s)
      ActionMailer::Base.deliveries.clear

      login(@admin)
      patch "/api/v2/admin/referee_assignments/#{assignment.id}",
            params: { assignment: { referee1_id: create(:referee, email: 'neu@example.de').id } }
      assert_response :success

      assert_nil assignment.reload.license_lists_notified_at
    end

    # Verlegung: Der bereits verschickte Link läuft am Tag nach dem ALTEN Termin
    # ab, taugt für den neuen Termin also nicht mehr.
    test 'Verlegung eines Spieltags gibt die Ansetzung an den Wochenlauf zurueck' do
      assignment = publish_assignment_for(Date.current + 2)
      assert_not_nil assignment.license_lists_notified_at
      game_day = assignment.game.game_day

      login(@admin)
      patch "/api/v2/game_days/#{game_day.id}",
            params: { game_day: { date: (Date.current + 30).to_s } }
      assert_response :success

      assert_nil assignment.reload.license_lists_notified_at
    end

    # Ohne lesbares Spieltagsdatum findet der Wochenlauf das Spiel nie. Dann darf
    # die Mail auch keine Folgemail versprechen.
    test 'ohne lesbares Spieltagsdatum verspricht die Mail keine Folgemail' do
      game_day = create(:game_day, league: @league, date: '2026-03-07')
      game_day.update_column(:date, 'unbekannt')
      game = create(:game, game_day: game_day, start_time: '14:00',
                           home_team: create(:team, league: @league), guest_team: create(:team, league: @league))
      assignment = RefereeAssignment.create!(game: game, referee1: @referee, status: 'tentative')

      login(@admin)
      perform_enqueued_jobs { post "/api/v2/admin/referee_assignments/#{assignment.id}/publish" }
      assert_response :success

      html_bodies.each do |body|
        assert_not_includes body, 'Lizenzlisten ansehen'
        assert_not_includes body, 'wenige Tage vor dem Spiel'
      end
    end

    # Der Kalendertermin gehört dagegen in jede Ansetzungsmail, egal wie weit das
    # Spiel entfernt ist.
    test 'der Kalendertermin liegt unabhaengig vom Abstand bei' do
      publish_assignment_for(Date.current + 21)

      ActionMailer::Base.deliveries.each do |mail|
        assert_equal 1, mail.attachments.size
        assert_includes mail.attachments.first.body.decoded, 'BEGIN:VEVENT'
      end
    end
  end
end
