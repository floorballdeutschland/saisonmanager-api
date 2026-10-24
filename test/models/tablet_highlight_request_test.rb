require 'test_helper'

# Anfrage "Link zum Kalibrieren schicken" (fe#560).
class TabletHighlightRequestTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @game = create(:game)
    @anfrage = TabletHighlightRequest.create!(game: @game, email: 'kamera@verein.de')
  end

  test 'ein Spiel mit offener oder verschickter Anfrage bleibt löschbar' do
    TabletHighlightRequest.create!(game: @game, email: 'zwei@verein.de').issue_token!

    assert_difference -> { TabletHighlightRequest.count }, -2 do
      @game.destroy!
    end
  end

  test 'der Fremdschlüssel löscht mit, auch ohne Rails-Rückrufe' do
    Game.where(id: @game.id).delete_all

    assert_not TabletHighlightRequest.exists?(@anfrage.id)
  end

  test 'nur ein Lauf beansprucht die Anfrage, ein veralteter zweiter bekommt nichts' do
    erster = TabletHighlightRequest.find(@anfrage.id)
    zweiter = TabletHighlightRequest.find(@anfrage.id)

    token = erster.claim!
    assert token.present?
    assert_nil zweiter.claim!, 'zweiter Lauf mit veraltetem Stand'
    assert_equal erster.reload.token_digest, Digest::SHA256.hexdigest(token), 'Link des ersten Laufs bleibt gültig'
    assert_nil erster.email
  end

  test 'der Rohtoken ist wiederholbar und hängt an Anfrage und Zufallsanteil' do
    andere = TabletHighlightRequest.create!(game: @game, email: 'b@verein.de')

    assert_equal @anfrage.raw_token, TabletHighlightRequest.find(@anfrage.id).raw_token
    assert_not_equal @anfrage.raw_token, andere.raw_token
    assert @anfrage.token_nonce.present?
  end
end
