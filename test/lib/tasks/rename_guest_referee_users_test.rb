require 'test_helper'
require 'rake'

# Tests für referees:rename_guest_users (lib/tasks/rename_guest_referee_users.rake).
class RenameGuestRefereeUsersTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    ActionMailer::Base.deliveries.clear
  end

  def run_task(env = {})
    task = Rake::Task['referees:rename_guest_users']
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io { task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def gastkonto(nachname:, user_name:, email: 'gast@example.org')
    referee = create(:referee, guest: true, lizenznummer: nil, nachname: nachname, email: email)
    create(:user, user_name: user_name, first_name: referee.vorname, email: email, referee_id: referee.id)
  end

  test 'benennt das Gastkonto um und schickt die Mail' do
    user = gastkonto(nachname: 'Serocki', user_name: 'sr-8725')

    run_task

    assert_equal 'sr-serocki', user.reload.user_name
    mail = ActionMailer::Base.deliveries.last
    assert_equal ['gast@example.org'], mail.to
    assert_includes mail.body.encoded, 'sr-serocki'
    assert_includes mail.body.encoded, 'sr-8725'
  end

  test 'DRY_RUN aendert nichts und verschickt nichts' do
    user = gastkonto(nachname: 'Serocki', user_name: 'sr-8725')

    out, = run_task('DRY_RUN' => '1')

    assert_equal 'sr-8725', user.reload.user_name
    assert_empty ActionMailer::Base.deliveries
    assert_includes out, 'sr-8725 → sr-serocki'
  end

  test 'ein passend benanntes Konto bleibt unberuehrt und bekommt keine Mail' do
    user = gastkonto(nachname: 'Serocki', user_name: 'sr-serocki')

    run_task

    assert_equal 'sr-serocki', user.reload.user_name
    assert_empty ActionMailer::Base.deliveries
  end

  test 'laesst Konten ohne Gast-Haken in Ruhe' do
    referee = create(:referee, guest: false, lizenznummer: 3204, nachname: 'Müller', email: 'schiri@example.org')
    user = create(:user, user_name: 'sr-3204', referee_id: referee.id)

    run_task

    assert_equal 'sr-3204', user.reload.user_name
    assert_empty ActionMailer::Base.deliveries
  end

  test 'zwei Gaeste gleichen Nachnamens bekommen verschiedene Namen' do
    first = gastkonto(nachname: 'Nielsen', user_name: 'sr-8725', email: 'a@example.org')
    second = gastkonto(nachname: 'Nielsen', user_name: 'sr-8726', email: 'b@example.org')

    run_task

    assert_equal %w[sr-nielsen sr-nielsen2], [first.reload.user_name, second.reload.user_name]
  end

  test 'ohne E-Mail-Adresse wird umbenannt, aber nicht benachrichtigt' do
    user = gastkonto(nachname: 'Serocki', user_name: 'sr-8725', email: nil)

    run_task

    assert_equal 'sr-serocki', user.reload.user_name
    assert_empty ActionMailer::Base.deliveries
  end
end
