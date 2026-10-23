require 'test_helper'

# Liga-JSON liefert die Feldgroesse samt Erbe der Hauptrunde (fe#592).
class LeagueEffectiveFieldSizeTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    @go = GameOperation.create!(name: 'Test GO', short_name: 'TGO')
    @hauptrunde = League.create!(game_operation: @go, name: 'Hauptrunde', season_id: '1',
                                 table_modus: 'classic', field_size: 'KF')
    @endrunde = League.create!(game_operation: @go, name: 'Endrunde', season_id: '1',
                               table_modus: 'classic', league_id_preround: @hauptrunde.id)
    Rails.cache.clear
  end

  test 'full_hash: Endrunde ohne field_size erbt KF der Hauptrunde' do
    hash = @endrunde.full_hash

    assert_nil hash[:field_size]
    assert_equal 'KF', hash[:effective_field_size]
  end

  test 'full_hash: eigene field_size geht vor' do
    @endrunde.update!(field_size: 'GF')

    assert_equal 'GF', @endrunde.reload.full_hash[:effective_field_size]
  end

  test 'full_hash: ohne Angabe und ohne Hauptrunde nil' do
    @hauptrunde.update!(field_size: nil)

    assert_nil @hauptrunde.reload.full_hash[:effective_field_size]
  end

  test 'GET leagues/:id liefert effective_field_size' do
    get "/api/v2/leagues/#{@endrunde.id}.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal 'KF', response.parsed_body['effective_field_size']
  end
end
