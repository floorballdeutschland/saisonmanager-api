require 'test_helper'

class ApiKeyUsageTest < ActiveSupport::TestCase
  setup { @key = create(:api_key) }

  test 'increment! zaehlt hoch statt zu duplizieren' do
    3.times { ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'leagues#schedule') }

    usages = ApiKeyUsage.where(api_key_id: @key.id)
    assert_equal 1, usages.count
    assert_equal 3, usages.first.count
  end

  test 'increment! trennt nach Endpunkt und Tag' do
    ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'leagues#schedule')
    ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'teams#stats')
    ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'leagues#schedule', date: Date.current - 1)

    assert_equal 3, ApiKeyUsage.where(api_key_id: @key.id).count
    assert_equal 3, ApiKeyUsage.where(api_key_id: @key.id).sum(:count)
  end

  test 'mit dem Key verschwindet seine Statistik' do
    ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'leagues#schedule')

    assert_difference 'ApiKeyUsage.count', -1 do
      @key.destroy
    end
  end

  test 'Antrag verliert beim Loeschen des Keys nur die Verknuepfung' do
    application = create(:api_key_application)
    application.approve!(1)
    application.reveal_key!
    key = application.reload.api_key

    assert_no_difference 'ApiKeyApplication.count' do
      key.destroy
    end
    assert_nil application.reload.api_key_id
    assert_equal 'approved', application.status
  end
end
