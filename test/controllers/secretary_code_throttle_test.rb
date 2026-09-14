require 'test_helper'

# Obergrenze fuers Einloesen des Sekretariats-Kurzcodes
# (config/initializers/rack_attack.rb, Toepfe 'secretary-code/ip' und
# 'secretary-code/ip/hour').
#
# Der Code ist acht Zeichen aus 32, also 40 Bit, und der Endpunkt verlangt weder
# Cookie noch API-Key. Diese Toepfe sind damit der einzige Schutz gegen das
# Durchprobieren -- deshalb hat er als einziger Topf einen eigenen Test.
#
# Aufbau wie CalendarThrottleTest: Cache-Store aus dem test_helper, travel_to auf
# den Minutenanfang, weil in einem festen Fenster gezaehlt wird.
class SecretaryCodeThrottleTest < ActionDispatch::IntegrationTest
  PATH = '/api/v2/public/secretary/redeem'.freeze

  test 'nach zehn Versuchen in der Minute wird gebremst' do
    travel_to Time.zone.now.beginning_of_minute do
      10.times { post PATH, params: { code: '2345ABCD' } }

      assert_response :gone

      post PATH, params: { code: '2345ABCD' }

      assert_response :too_many_requests
      assert JSON.parse(response.body)['error'].present?
      assert response.headers['Retry-After'].present?
    end
  end

  # Der Grund fuer `start_with?` statt `==`: Die Route traegt wie jede
  # Rails-Route ein `(.:format)`. Mit dem exakten Vergleich lief `…/redeem.json`
  # in dieselbe Action, ohne dass einer der Toepfe zaehlte -- das Geheimnis war
  # damit mit fuenf angehaengten Zeichen ungebremst ratbar.
  test 'eine angehaengte Endung umgeht die Grenze nicht' do
    travel_to Time.zone.now.beginning_of_minute do
      11.times { post "#{PATH}.json", params: { code: '2345ABCD' } }

      assert_response :too_many_requests
    end
  end

  # Den Schraegstrich raeumt Rails schon vor Rack::Attack weg, er war also nie
  # ein Loch. Der Test haelt das fest, weil es an der Wegfindung haengt und
  # nicht an dieser Datei.
  test 'ein Schraegstrich am Ende umgeht die Grenze nicht' do
    travel_to Time.zone.now.beginning_of_minute do
      11.times { post "#{PATH}/", params: { code: '2345ABCD' } }

      assert_response :too_many_requests
    end
  end

  # Ein Sekretariat tippt den Code ein- bis zweimal. Die Grenze darf das nicht
  # treffen: In der Halle haengen alle Rechner hinter derselben Adresse.
  test 'zwei Anlaeufe laufen nicht in die Grenze' do
    user = create(:user)
    game_day = create(:game_day)
    _link, _raw_token, raw_code = GameDaySecretaryLink.generate!(game_days: [game_day], created_by: user)

    travel_to Time.zone.now.beginning_of_minute do
      post PATH, params: { code: 'FALSCH12' }
      post PATH, params: { code: raw_code }

      assert_response :success
    end
  end

  # Gegenprobe: Der Topf gilt nur diesem Endpunkt und darf den Lesepfad des
  # Sekretariats nicht mitbremsen -- der wird am Spieltisch staendig neu geladen.
  test 'der Lesepfad mit Token bleibt unberuehrt' do
    user = create(:user)
    game_day = create(:game_day)
    _link, raw_token, _raw_code = GameDaySecretaryLink.generate!(game_days: [game_day], created_by: user)

    travel_to Time.zone.now.beginning_of_minute do
      15.times { get '/api/v2/public/secretary', params: { token: raw_token } }

      assert_response :success
    end
  end
end
