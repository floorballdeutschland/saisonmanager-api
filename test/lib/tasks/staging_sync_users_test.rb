require 'test_helper'
require 'rake'

# Tests für staging:sync_users (lib/tasks/staging_sync_users.rake): Nachziehen
# des Prod-Benutzerkontenstands auf die Staging-DB, ohne den Rest der Datenbank
# anzufassen.
#
# Der Task verweigert die Arbeit gegen jede Datenbank, deren Host nicht
# 'staging' enthält. Die Testdatenbank ist keine, deshalb wird
# connection_db_config für die Dauer des Aufrufs auf einen Staging-Host
# gestellt – die Prüfung selbst ist Gegenstand eines eigenen Tests.
class StagingSyncUsersTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['staging:sync_users']
    @task.reenable
  end

  STAGING_CONFIG = Struct.new(:configuration_hash).new(host: 'postgres-staging').freeze

  def run_task(records, env = {}, host_config: STAGING_CONFIG)
    saved_env = ENV.to_hash.slice(*env.keys)
    saved_stdin = $stdin
    env.each { |k, v| ENV[k] = v }
    $stdin = StringIO.new(records.is_a?(String) ? records : records.to_json)
    @task.reenable
    capture_io do
      ActiveRecord::Base.stub(:connection_db_config, host_config) { @task.invoke }
    end
  ensure
    $stdin = saved_stdin
    env.each_key { |k| ENV[k] = saved_env[k] }
  end

  def prod_record(user_name, permissions, extra = {})
    {
      'user_name' => user_name,
      'email' => "#{user_name}@example.com",
      'first_name' => 'Vor',
      'last_name' => 'Nach',
      'password_digest' => BCrypt::Password.create('prod-passwort'),
      'permissions' => permissions,
      'language' => 'de',
      'receive_info_mails' => true,
      'privacy_approved' => true,
      'description' => nil,
      'archived_at' => nil
    }.merge(extra)
  end

  SBK = [{ 'user_group_id' => 2, 'game_operation_id' => 8 }].freeze
  VM  = [{ 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => 1 }].freeze

  test 'neues SBK-Konto wird angelegt und behält sein Prod-Passwort' do
    digest = BCrypt::Password.create('prod-passwort')

    run_task([prod_record('neue.sbk', SBK, 'password_digest' => digest)])

    user = User.find_by(user_name: 'neue.sbk')
    assert_not_nil user
    assert_equal SBK, user.permissions
    assert user.authenticate('prod-passwort'), 'Das echte Prod-Passwort muss auf Staging funktionieren'
  end

  test 'bestehendes Konto behält seine Staging-ID' do
    existing = create(:user, :sbk_scoped, user_name: 'alte.sbk', last_name: 'Alt')

    run_task([prod_record('alte.sbk', SBK, 'last_name' => 'Neu')])

    assert_equal existing.id, User.find_by(user_name: 'alte.sbk').id
    assert_equal 'Neu', existing.reload.last_name
  end

  test 'reines VM-Konto wird nicht neu angelegt' do
    run_task([prod_record('nur.vm', VM)])

    assert_nil User.find_by(user_name: 'nur.vm')
  end

  test 'bestehendes Konto verliert entzogene Rollen' do
    create(:user, :sbk_scoped, user_name: 'war.sbk')

    run_task([prod_record('war.sbk', VM)])

    assert_equal VM, User.find_by(user_name: 'war.sbk').permissions,
                 'Rechte, die es auf Prod nicht mehr gibt, dürfen auf Staging nicht bleiben'
  end

  test 'demo-Konten werden nicht überschrieben' do
    create(:user, :admin, user_name: 'demo_admin', last_name: 'Demo')

    run_task([prod_record('demo_admin', SBK, 'last_name' => 'Fremd')])

    assert_equal 'Demo', User.find_by(user_name: 'demo_admin').last_name
  end

  test 'unbekannte referee_id blockiert das Konto nicht' do
    run_task([prod_record('mit.schiri', SBK, 'referee_id' => 999_999)])

    user = User.find_by(user_name: 'mit.schiri')
    assert_not_nil user, 'Ein Fremdschlüssel ins Leere darf das Konto nicht scheitern lassen'
    assert_nil user.referee_id
  end

  test 'DRY_RUN schreibt nicht' do
    run_task([prod_record('nur.probe', SBK)], 'DRY_RUN' => 'true')

    assert_nil User.find_by(user_name: 'nur.probe')
  end

  test 'gegen eine Nicht-Staging-Datenbank bricht der Task ab' do
    prod_config = Struct.new(:configuration_hash).new(host: 'postgres')

    assert_raises(SystemExit) do
      run_task([prod_record('neue.sbk', SBK)], {}, host_config: prod_config)
    end
    assert_nil User.find_by(user_name: 'neue.sbk')
  end

  test 'leerer Export bricht ab, statt Konten zu verwerfen' do
    assert_raises(SystemExit) { run_task([]) }
  end

  test 'kaputtes JSON bricht ab' do
    assert_raises(SystemExit) { run_task('{kein json') }
  end
end
