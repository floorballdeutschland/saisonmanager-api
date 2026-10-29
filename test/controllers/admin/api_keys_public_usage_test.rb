require 'test_helper'

class AdminApiKeysPublicUsageTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
  end

  test 'Admin sieht die Zugriffe anonymer Website-Besucher' do
    PublicSessionUsage.increment!(endpoint: 'leagues#schedule')
    PublicSessionUsage.increment!(endpoint: 'leagues#schedule')
    PublicSessionUsage.increment!(endpoint: 'games#show', date: Date.current - 40)
    login(create(:user, :admin))

    get '/api/v2/admin/api_keys/public_usage'

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal(2, body['last_30_days'].sum { |d| d['count'] })
    assert_equal [{ 'endpoint' => 'leagues#schedule', 'count' => 2 }], body['by_endpoint']
    assert_equal PublicSession::RATE_LIMIT_PER_MINUTE, body['rate_limit']
    assert_equal 12, body['last_year'].size
  end

  test 'ohne Adminrechte kein Zugriff' do
    login(create(:user))

    get '/api/v2/admin/api_keys/public_usage'

    assert_response :forbidden
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
