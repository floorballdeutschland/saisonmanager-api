require 'test_helper'

class RefereeClubExclusionRequestTest < ActiveSupport::TestCase
  setup do
    @club = create(:club)
    @own_club = create(:club)
    @referee = create(:referee, club: @own_club)
  end

  test 'add-Antrag ist gueltig fuer einen noch nicht gelisteten Verein' do
    request = build_request(club: @club, kind: 'add')

    assert request.valid?
  end

  test 'add-Antrag fuer den eigenen Verein ist unzulaessig' do
    request = build_request(club: @own_club, kind: 'add')

    assert_not request.valid?
    assert_includes request.errors.full_messages.join, 'bereits auf deiner Liste'
  end

  test 'add-Antrag fuer einen bereits gelisteten Verein ist unzulaessig' do
    RefereeClubExclusion.create!(referee: @referee, club: @club, reason: 'Alt')

    request = build_request(club: @club, kind: 'add')

    assert_not request.valid?
  end

  test 'remove-Antrag ohne Listeneintrag ist unzulaessig' do
    request = build_request(club: @club, kind: 'remove')

    assert_not request.valid?
    assert_includes request.errors.full_messages.join, 'nicht auf deiner Liste'
  end

  test 'remove-Antrag fuer den eigenen Verein ist unzulaessig' do
    request = build_request(club: @own_club, kind: 'remove')

    assert_not request.valid?
    assert_includes request.errors.full_messages.join, 'eigene Verein'
  end

  test 'zweiter offener Antrag zum selben Verein ist unzulaessig' do
    build_request(club: @club, kind: 'add').save!

    duplicate = build_request(club: @club, kind: 'add')

    assert_not duplicate.valid?
    assert_includes duplicate.errors.full_messages.join, 'offener Antrag'
  end

  test 'Begruendung ist Pflicht und auf 120 Zeichen begrenzt' do
    assert_not build_request(club: @club, kind: 'add', reason: '').valid?
    assert_not build_request(club: @club, kind: 'add', reason: 'x' * 121).valid?
  end

  test 'approve legt den Ausschluss an und uebernimmt die Begruendung' do
    request = build_request(club: @club, kind: 'add', reason: 'Sohn spielt dort')
    request.save!

    assert request.approve!(42)

    exclusion = RefereeClubExclusion.find_by(referee: @referee, club: @club)
    assert_not_nil exclusion
    assert_equal 'Sohn spielt dort', exclusion.reason
    assert_equal 42, exclusion.created_by
    assert_equal request.id, exclusion.request_id
    assert_equal 'approved', request.reload.status
  end

  test 'approve eines remove-Antrags streicht den Ausschluss' do
    RefereeClubExclusion.create!(referee: @referee, club: @club, reason: 'Alt')
    request = build_request(club: @club, kind: 'remove', reason: 'Nicht mehr noetig')
    request.save!

    assert request.approve!(42)

    assert_nil RefereeClubExclusion.find_by(referee: @referee, club: @club)
  end

  test 'approve eines bereits entschiedenen Antrags wirkt nicht doppelt' do
    request = build_request(club: @club, kind: 'add')
    request.save!
    request.reject!(1, 'Passt so nicht')

    assert_not request.approve!(2)
    assert_equal 'rejected', request.reload.status
    assert_nil RefereeClubExclusion.find_by(referee: @referee, club: @club)
  end

  test 'Ausschluss fuer den eigenen Verein laesst sich nicht direkt anlegen' do
    exclusion = RefereeClubExclusion.new(referee: @referee, club: @own_club, reason: 'Direkt')

    assert_not exclusion.valid?
    assert_includes exclusion.errors.full_messages.join, 'eigene Verein'
  end

  test 'approve eines add-Antrags legt nichts an, wenn der Verein inzwischen der eigene ist' do
    request = build_request(club: @club, kind: 'add')
    request.save!
    @referee.update!(club: @club)

    assert request.approve!(42)

    assert_equal 'approved', request.reload.status
    assert_nil RefereeClubExclusion.find_by(referee: @referee, club: @club)
  end

  test 'withdraw zieht nur offene Antraege zurueck' do
    request = build_request(club: @club, kind: 'add')
    request.save!

    assert request.withdraw!
    assert_equal 'withdrawn', request.reload.status
    assert_not request.withdraw!
  end

  private

  def build_request(club:, kind:, reason: 'Befangenheit')
    RefereeClubExclusionRequest.new(referee: @referee, club: club, kind: kind, reason: reason)
  end
end
