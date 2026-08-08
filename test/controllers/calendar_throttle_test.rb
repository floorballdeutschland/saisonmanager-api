require 'test_helper'

# Obergrenze für Kalender-Abos (config/initializers/rack_attack.rb, Throttle
# 'calendar/ip').
#
# Die Kalender-Endpunkte sind der einzige öffentliche Bereich ohne Cookie UND
# ohne API-Key. Beide anderen Netze greifen dort nicht: 'api/key' zählt nur Keys
# mit gesetzter Grenze, 'crawler/ip' nur bekannte Kennungen. Ohne diesen Topf
# liefe ein Aufruf mit gewöhnlicher Browser-Kennung völlig ungebremst.
#
# Aufbau wie CrawlerThrottleTest: Cache-Store aus dem test_helper, und travel_to
# auf den Minutenanfang, weil in einem festen Fenster gezählt wird.
class CalendarThrottleTest < ActionDispatch::IntegrationTest
  BROWSER = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
            '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'.freeze

  setup do
    create(:setting)
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    league = create(:league, game_operation: go)
    club = create(:club)
    @team = create(:team, league:, club:)
  end

  # Der Kern: gewöhnliche Browser-Kennung, kein Key, kein Cookie – genau die
  # Kombination, die durch alle anderen Netze fällt.
  test 'ein Kalender-Abruf ohne Key wird nach 30 Aufrufen pro Minute gebremst' do
    travel_to Time.zone.now.beginning_of_minute do
      30.times { get calendar_path, headers: { 'HTTP_USER_AGENT' => BROWSER } }
      assert_response :success

      get calendar_path, headers: { 'HTTP_USER_AGENT' => BROWSER }

      assert_response :too_many_requests
      assert JSON.parse(response.body)['error'].present?
      assert response.headers['Retry-After'].present?
    end
  end

  # Ein echtes Abo ruft höchstens stündlich ab, ein Mensch klickt einzeln. Die
  # Grenze darf beides nicht treffen, sonst bricht der Fix genau das, was er
  # herstellen soll.
  test 'ein gewoehnliches Abo laeuft nicht in die Grenze' do
    travel_to Time.zone.now.beginning_of_minute do
      5.times { get calendar_path, headers: { 'HTTP_USER_AGENT' => BROWSER } }

      assert_response :success
    end
  end

  # Gegenprobe: Der Topf gilt nur den Kalender-Pfaden und darf die übrigen
  # öffentlichen Endpunkte nicht mitbremsen – die hängen bereits am Key-Throttle.
  test 'andere oeffentliche Endpunkte bleiben unberuehrt' do
    travel_to Time.zone.now.beginning_of_minute do
      31.times { get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => BROWSER } }

      assert_response :success
    end
  end

  private

  def calendar_path
    "/api/v2/calendar/teams/#{@team.id}.ics"
  end
end
