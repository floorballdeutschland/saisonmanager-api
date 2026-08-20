require 'test_helper'

# Die Strafenkataloge werden aus Setting.current gelesen und um den Schluessel
# 'id' ergaenzt. Seit Setting.current die Konfiguration je Anfrage memoisiert,
# ist die Rueckgabe fuer alle Aufrufer einer Anfrage dieselbe Instanz — eine
# Ergaenzung an Ort und Stelle landet damit IN der Konfiguration, markiert das
# Attribut als geaendert und wuerde von einem spaeteren save! derselben Anfrage
# mitgeschrieben (Admin::PenaltyCodesController#persist speichert genau diese
# Instanz). Vorher lieferte der Marshal-Rundlauf des MemoryStore je Aufruf eine
# eigene Kopie und hat das verdeckt.
#
# Geprueft wird die Instanz WAEHREND der Anfrage: Danach hat der Executor
# Current zurueckgesetzt, und ein Blick in die Datenbank liefe ins Leere, weil
# die Mutation nur im Speicher steht — der Test waere tautologisch.
class PenaltiesCatalogIsolationTest < ActionDispatch::IntegrationTest
  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  # Zustand der geteilten Konfiguration am Ende der Aktion, noch innerhalb des
  # Executors.
  def dirty_attributes_during(path)
    dirty = nil
    subscriber = ActiveSupport::Notifications.subscribe('process_action.action_controller') do
      dirty = Setting.current.changed
    end
    get path
    dirty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  setup do
    create(:setting,
           penalties: { '1' => { 'name' => 'Beinstellen', 'order' => 1 } },
           penalty_codes: { '901' => { 'description' => 'Spieldauer', 'active' => true } })
    login(create(:user, :admin))
  end

  test 'GET user/leagues/penalties laesst die geteilte Konfiguration sauber' do
    dirty = dirty_attributes_during('/api/v2/user/leagues/penalties.json')

    assert_response :success
    assert_equal '1', response.parsed_body.first['id'], 'Testaufbau: die Antwort traegt die id'
    assert_equal [], dirty, 'der Lesezugriff darf die Konfiguration nicht veraendern'
  end

  test 'GET user/leagues/penalty_codes laesst die geteilte Konfiguration sauber' do
    dirty = dirty_attributes_during('/api/v2/user/leagues/penalty_codes.json')

    assert_response :success
    assert_equal '901', response.parsed_body.first['id'], 'Testaufbau: die Antwort traegt die id'
    assert_equal [], dirty, 'der Lesezugriff darf die Konfiguration nicht veraendern'
  end
end
