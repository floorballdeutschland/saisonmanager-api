require 'test_helper'

# Ohne Accept-Header (oder mit dem eines Browsers) nimmt Rails HTML an. Für
# Endpunkte mit jbuilder-Vorlage oder `respond_to` ohne HTML-Zweig hieß das 500.
# Unter api/v2 gibt es kein HTML, ohne Endung gilt deshalb JSON.
class ApiDefaultJsonFormatTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze # test/fixtures/api_keys.yml

  setup do
    create(:setting)
    # Die leeren Fixture-Ligen haben keinen Spielbetrieb, an dem die
    # Listenvorlage den Namen nachschlägt.
    League.where(game_operation_id: nil).delete_all
    @league = create(:league)
    @game = create(:game, game_day: create(:game_day, league: @league))
  end

  [nil, '', 'text/html', 'text/html,application/xhtml+xml,*/*;q=0.8'].each do |accept|
    %w[leagues leagues/:league games/:game].each do |pfad|
      test "#{pfad} mit Accept #{accept.inspect} liefert JSON" do
        url = "/api/v2/#{pfad.sub(':league', @league.id.to_s).sub(':game', @game.id.to_s)}"
        get url, headers: { 'X-Api-Key' => API_KEY, 'Accept' => accept }

        assert_response :success
        assert_equal 'application/json', response.media_type
        assert_nothing_raised { response.parsed_body }
      end
    end
  end

  test 'eine Endung behält Vorrang' do
    get "/api/v2/calendar/leagues/#{@league.id}", headers: { 'X-Api-Key' => API_KEY, 'Accept' => '' }

    assert_response :success
    assert_equal 'text/calendar', response.media_type
  end
end
