require 'test_helper'

module Admin
  class SystemHealthControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @go = create(:game_operation)
    end

    test 'Nicht-Admin bekommt keinen Zugriff' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))
      get '/api/v2/admin/system_health'
      assert_response :forbidden
    end

    test 'Admin bekommt Platten-, Upload- und Datenbankkennzahlen' do
      login(@admin)
      get '/api/v2/admin/system_health'

      assert_response :success
      body = response.parsed_body

      assert_includes SystemHealth::STATUSES, body['status']
      assert_equal SystemHealth::WARNING_PERCENT, body['thresholds']['warning_percent']
      assert_equal SystemHealth::CRITICAL_PERCENT, body['thresholds']['critical_percent']

      # Der Disk-Service ist im Test ein lokales Verzeichnis, `df` liefert also
      # echte Werte. Nur die Struktur prüfen, nicht die Zahlen.
      assert body['disk'].key?('used_percent')
      assert_equal 0, body['uploads']['blob_count']
      assert body['database']['size_bytes'].positive?
      assert_equal SystemHealth::HISTORY_MONTHS, body['growth']['months'].size
      assert_equal SAISONMANAGER_VERSION, body['operations']['version']
    end

    test 'Der gemessene Verlauf kommt aus den Tageswerten' do
      DailyMetric.set!(SystemHealth::DISK_METRIC_KEY, 42, Date.current - 1)
      DailyMetric.set!(SystemHealth::DISK_METRIC_KEY, 43, Date.current)

      login(@admin)
      get '/api/v2/admin/system_health'

      assert_response :success
      history = response.parsed_body['disk']['history']
      assert_equal([42, 43], history.map { |h| h['used_percent'] })
    end

    test 'Uploads werden nach Art aufgeschluesselt und Verwaiste ausgewiesen' do
      club = create(:club)
      club.logo.attach(io: StringIO.new('x' * 2048), filename: 'logo.png', content_type: 'image/png')
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new('y' * 512), filename: 'waise.pdf')

      login(@admin)
      get '/api/v2/admin/system_health'

      assert_response :success
      uploads = response.parsed_body['uploads']
      assert_equal 2, uploads['blob_count']
      assert_equal 1, uploads['unattached_count']

      logo_row = uploads['by_kind'].find { |row| row['name'] == 'logo' }
      assert_equal 'Club', logo_row['record_type']
      assert_equal 1, logo_row['count']
      assert_equal 2048, logo_row['total_bytes']
    end

    test 'Die Kurzfassung liefert nur den Plattenzustand' do
      login(@admin)
      get '/api/v2/admin/system_health/summary'

      assert_response :success
      body = response.parsed_body
      assert_equal %w[status used_percent free_bytes].sort, body.keys.sort
      assert_includes SystemHealth::STATUSES, body['status']
    end

    test 'Die Kurzfassung ist ebenfalls Admin-Sache' do
      login(create(:user, :sbk_global))
      get '/api/v2/admin/system_health/summary'
      assert_response :forbidden
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
