require 'test_helper'

# Geburtsdatum-Korrekturen: birthdate ist eine date-Spalte – unlesbare Werte
# dürfen das bestehende Geburtsdatum weder beim Anlegen noch beim Genehmigen
# still löschen (AR castet unlesbare Strings sonst zu nil).
class PlayerChangeRequestTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @player = create(:player, birthdate: '1990-01-01', clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
  end

  def build_request(new_value)
    PlayerChangeRequest.new(player: @player, club: @club, correction_type: 'birthdate',
                            status: 'pending', new_value: new_value)
  end

  test 'unlesbares Geburtsdatum wird schon beim Anlegen abgelehnt' do
    request = build_request('unbekannt')
    assert_not request.valid?
    assert request.errors[:new_value].any?
  end

  test 'apply! mit unlesbarem Geburtsdatum löscht das Geburtsdatum nicht' do
    request = build_request('ca. 1990')
    request.save!(validate: false) # Altbestand, der vor der Validierung entstand

    assert_raises(ActiveRecord::RecordInvalid) { request.apply!(1) }
    assert_equal Date.new(1990, 1, 1), @player.reload.birthdate
    assert_equal 'pending', request.reload.status
  end

  test 'apply! übernimmt ISO- und deutsches Format korrekt' do
    build_request('1991-02-03').tap(&:save!).apply!(1)
    assert_equal Date.new(1991, 2, 3), @player.reload.birthdate

    build_request('04.05.1992').tap(&:save!).apply!(1)
    assert_equal Date.new(1992, 5, 4), @player.reload.birthdate
  end
end
