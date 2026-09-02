require 'test_helper'

class GameDayOverlayLinkTest < ActiveSupport::TestCase
  setup do
    @game_day = create(:game_day)
    @user = create(:user, :admin)
  end

  test 'erneutes Erzeugen zieht den alten Zugang zurück' do
    old_link, old_token = GameDayOverlayLink.generate!(game_day: @game_day, created_by: @user)
    new_link, new_token = GameDayOverlayLink.generate!(game_day: @game_day, created_by: @user)

    assert_equal 1, GameDayOverlayLink.where(game_day: @game_day).count
    assert_not_equal old_link.id, new_link.id
    assert_nil GameDayOverlayLink.find_by_token(old_token)
    assert_equal new_link, GameDayOverlayLink.find_by_token(new_token)
  end

  # Der Riegel liegt in der Datenbank und nicht bloß in generate!: Zwei
  # gleichzeitige Klicks (Spielbericht und Sekretariats-Übersicht) konnten beide
  # erst löschen und dann anlegen. Zwei aktive Zeilen hätten die Übersicht dazu
  # gebracht, einen beliebigen der beiden Ersteller samt seinem Ablaufzeitpunkt
  # zu nennen -- eine falsche Auskunft darüber, wem der Zugang gehört.
  test 'ein zweiter Zugang für denselben Spieltag ist in der Datenbank gesperrt' do
    GameDayOverlayLink.generate!(game_day: @game_day, created_by: @user)

    assert_raises(ActiveRecord::RecordNotUnique) do
      GameDayOverlayLink.create!(
        game_day: @game_day,
        created_by: @user,
        token_digest: Digest::SHA256.hexdigest('zweiter'),
        expires_at: 1.hour.from_now
      )
    end
  end

  test 'ein abgelaufener Zugang gilt nicht mehr' do
    link, raw_token = GameDayOverlayLink.generate!(game_day: @game_day, created_by: @user)
    link.update!(expires_at: 1.second.ago)

    assert_nil GameDayOverlayLink.find_by_token(raw_token)
  end
end
