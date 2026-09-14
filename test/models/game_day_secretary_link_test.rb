require 'test_helper'

class GameDaySecretaryLinkTest < ActiveSupport::TestCase
  setup do
    @user = create(:user)
    @game_day = create(:game_day)
  end

  test 'generate! liefert einen achtstelligen Code aus dem vorgesehenen Alphabet' do
    _link, _raw_token, raw_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    assert_equal GameDaySecretaryLink::CODE_LENGTH, raw_code.length
    assert raw_code.each_char.all? { |char| GameDaySecretaryLink::CODE_ALPHABET.include?(char) },
           "Code #{raw_code} enthaelt Zeichen ausserhalb des Alphabets"
  end

  test 'generate! legt den Code nur als Digest ab' do
    link, _raw_token, raw_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    assert_not_equal raw_code, link.code_digest
    assert_equal Digest::SHA256.hexdigest(raw_code), link.code_digest
  end

  test 'redeem liefert genau den Token, den generate! ausgegeben hat' do
    link, raw_token, raw_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    redeemed_link, redeemed_token = GameDaySecretaryLink.redeem(raw_code)

    assert_equal link.id, redeemed_link.id
    assert_equal raw_token, redeemed_token
  end

  test 'redeem liefert bei jedem Aufruf denselben Token' do
    # Zwei Registerkarten am selben Tisch loesen denselben Code ein
    # (sessionStorage gilt je Registerkarte). Ein frisch ausgestellter Token
    # wuerde die erste Registerkarte mitten im Spiel aussperren.
    _link, _raw_token, raw_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    _first_link, first_token = GameDaySecretaryLink.redeem(raw_code)
    _second_link, second_token = GameDaySecretaryLink.redeem(raw_code)

    assert_equal first_token, second_token
  end

  test 'der eingeloeste Token authentifiziert wie ein regulaerer' do
    _link, _raw_token, raw_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)
    _redeemed_link, redeemed_token = GameDaySecretaryLink.redeem(raw_code)

    found = GameDaySecretaryLink.find_by_token(redeemed_token)

    assert_not_nil found
    assert found.covers_game_day?(@game_day.id)
  end

  test 'redeem nimmt Kleinschreibung, Trennzeichen und die verwechselten Buchstaben an' do
    _link, _raw_token, raw_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    # So, wie es vom Zettel abgetippt ankommt: klein, mit Bindestrich, und mit
    # den Buchstaben, die es im Alphabet gar nicht gibt.
    typed = "#{raw_code[0, 4]}-#{raw_code[4, 4]}".downcase.tr('01', 'ol')

    assert_not_nil GameDaySecretaryLink.redeem(typed)
  end

  test 'redeem weist Unbrauchbares ab, ohne zu werfen' do
    assert_nil GameDaySecretaryLink.redeem(nil)
    assert_nil GameDaySecretaryLink.redeem('')
    assert_nil GameDaySecretaryLink.redeem('ABC')
    assert_nil GameDaySecretaryLink.redeem('ABCDEFGHIJKLMNOP')
    assert_nil GameDaySecretaryLink.redeem('ÄÖÜ12345')
  end

  test 'redeem weist einen abgelaufenen Code ab' do
    link, _raw_token, raw_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)
    link.update!(expires_at: 1.minute.ago)

    assert_nil GameDaySecretaryLink.redeem(raw_code)
  end

  test 'ein neu ausgegebener Link entwertet den Code des vorherigen' do
    _link, _raw_token, first_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)
    _second, _second_token, second_code = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    assert_nil GameDaySecretaryLink.redeem(first_code)
    assert_not_nil GameDaySecretaryLink.redeem(second_code)
  end

  test 'normalize_code laesst das gespeicherte Format unveraendert' do
    assert_equal 'ABCD2345', GameDaySecretaryLink.normalize_code('ABCD2345')
  end
end
