require 'test_helper'

# Die Erinnerung geht mit dem ANPFIFF raus, nicht nach dem Spiel: Der Coach soll
# den Bogen während des Spiels aufschlagen können. Das ist der bewusste
# Unterschied zum Vereins-Feedback, dessen Fenster erst 24 h nach dem Spiel
# öffnet.
class RefereeObservationReminderTest < ActiveSupport::TestCase
  setup do
    @coach = create(:referee, email: 'coach@example.org')
    create(:user, referee: @coach, receive_info_mails: true)
  end

  test 'erinnert den angesetzten Coach nach dem Anpfiff' do
    assignment = assignment_for(kickoff: 2.hours.ago)

    assert_difference 'ActionMailer::Base.deliveries.size', 1 do
      assert_equal 1, RefereeObservationReminder.new(assignment).notify(deliver_now: true)
    end
    assert_not_nil assignment.reload.observation_reminder_sent_at
  end

  test 'erinnert vor dem Anpfiff nicht' do
    assignment = assignment_for(kickoff: 2.hours.from_now)

    assert_equal 0, RefereeObservationReminder.new(assignment).notify(deliver_now: true)
    assert_nil assignment.reload.observation_reminder_sent_at
  end

  test 'erinnert nicht zweimal' do
    assignment = assignment_for(kickoff: 2.hours.ago)
    RefereeObservationReminder.new(assignment).notify(deliver_now: true)

    assert_difference 'ActionMailer::Base.deliveries.size', 0 do
      RefereeObservationReminder.new(assignment.reload).notify(deliver_now: true)
    end
  end

  test 'erinnert nicht, wenn der Bogen bereits abgegeben ist' do
    assignment = assignment_for(kickoff: 2.hours.ago)
    create(:referee_observation, :with_rating, game: assignment.game, coach: @coach)

    assert_equal 0, RefereeObservationReminder.new(assignment).notify(deliver_now: true)
  end

  test 'erinnert nicht ohne ermittelbaren Anpfiff' do
    assignment = assignment_for(kickoff: 2.hours.ago)
    assignment.game.game_day.update_column(:date, 'kein Datum')

    assert_equal 0, RefereeObservationReminder.new(assignment.reload).notify(deliver_now: true),
                 'Ohne Anpfiff wird gewartet, nicht sofort erinnert'
    assert_nil assignment.reload.observation_reminder_sent_at
  end

  test 'erinnert nicht bei abbestellten Info-Mails' do
    User.where(referee_id: @coach.id).update_all(receive_info_mails: false)
    assignment = assignment_for(kickoff: 2.hours.ago)

    assert_equal 0, RefereeObservationReminder.new(assignment).notify(deliver_now: true)
  end

  test 'erinnert nicht ohne Benutzerkonto' do
    coach = create(:referee, email: 'ohne-konto@example.org')
    assignment = assignment_for(kickoff: 2.hours.ago, coach: coach)

    assert_equal 0, RefereeObservationReminder.new(assignment).notify(deliver_now: true)
  end

  test 'due_assignments findet nur veroeffentlichte Ansetzungen mit Coach' do
    published = assignment_for(kickoff: 2.hours.ago)
    tentative = assignment_for(kickoff: 2.hours.ago, status: 'tentative')
    without_coach = RefereeAssignment.create!(
      game: game_at(2.hours.ago), referee1: create(:referee), status: 'published'
    )

    ids = RefereeObservationReminder.due_assignments.pluck(:id)
    assert_includes ids, published.id
    assert_not_includes ids, tentative.id
    assert_not_includes ids, without_coach.id
  end

  test 'due_assignments greift nicht in den Altbestand' do
    old = assignment_for(kickoff: (RefereeObservationReminder::LOOKBACK_DAYS + 5).days.ago)

    assert_not_includes RefereeObservationReminder.due_assignments.pluck(:id), old.id
  end

  # Ein fehlgeschlagener Versand darf den Cron-Durchlauf nicht abbrechen, und die
  # Ansetzung muss trotzdem markiert werden -- sonst versucht es jeder folgende
  # Lauf endlos erneut.
  test 'markiert auch bei Versandfehler und wirft nicht' do
    assignment = assignment_for(kickoff: 2.hours.ago)
    RefereeMailer.stub :observation_due, ->(*) { raise 'SMTP kaputt' } do
      assert_equal 0, RefereeObservationReminder.new(assignment).notify(deliver_now: true)
    end

    assert_not_nil assignment.reload.observation_reminder_sent_at
  end

  private

  def game_at(kickoff)
    time = kickoff.in_time_zone(GameKickoff::ZONE)
    game_day = create(:game_day, date: time.strftime('%Y-%m-%d'))
    create(:game, game_day: game_day, start_time: time.strftime('%H:%M'))
  end

  def assignment_for(kickoff:, coach: @coach, status: 'published')
    RefereeAssignment.create!(game: game_at(kickoff), coach: coach, status: status)
  end
end
