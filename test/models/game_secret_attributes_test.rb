require 'test_helper'

# Der Prüfwert des Einspruchslinks darf nicht über eine pauschale
# Serialisierung herausgehen, etwa über `render json: game` in
# GamesController#set_game_status, das Ausrichter und Sekretariats-Link sehen.
class GameSecretAttributesTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @game = create(:game, checklist_veto_token_digest: Digest::SHA256.hexdigest('geheim'))
  end

  test 'as_json enthält den Prüfwert des Einspruchslinks nicht' do
    json = @game.as_json

    assert_not_includes json.keys, 'checklist_veto_token_digest'
    assert_includes json.keys, 'checklist_veto_submitted_at', 'reguläre Felder bleiben erhalten'
  end

  test 'as_json mit except ergänzt den Prüfwert' do
    json = @game.as_json(except: :game_number)

    assert_not_includes json.keys, 'game_number'
    assert_not_includes json.keys, 'checklist_veto_token_digest'
  end
end
