require 'test_helper'

class RefereeObservationTest < ActiveSupport::TestCase
  test 'Bewertung ausserhalb 1 bis 7 wird abgewiesen' do
    observation = build(:referee_observation, :with_rating, pair_overall_rating: 8)
    assert_not observation.valid?
    assert_includes observation.errors.attribute_names, :pair_overall_rating
  end

  test 'fehlender Pflichttext wird abgewiesen' do
    observation = build(:referee_observation, :with_rating, final_comments: nil)
    assert_not observation.valid?
    assert_includes observation.errors.attribute_names, :final_comments
  end

  test 'Bogen ohne bewertete Person ist ungueltig' do
    observation = build(:referee_observation)
    assert_not observation.valid?
    assert_includes observation.errors.attribute_names, :ratings
  end

  test 'personenbezogene Bewertung ausserhalb 1 bis 7 wird abgewiesen' do
    observation = build(:referee_observation, :with_rating)
    observation.ratings.first.stick_play_rating = 0
    assert_not observation.valid?
  end

  test 'zweiter Bogen desselben Coaches zum selben Spiel ist ungueltig' do
    first = create(:referee_observation, :with_rating)
    duplicate = build(:referee_observation, :with_rating, game: first.game, coach: first.coach)

    assert_not duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :game_id
  end

  test 'for_referee findet den Bogen ueber die personenbezogene Bewertung' do
    referee = create(:referee)
    observation = create(:referee_observation, :with_rating, rated_referee: referee)
    create(:referee_observation, :with_rating)

    assert_equal [observation.id], RefereeObservation.for_referee(referee.id).pluck(:id)
  end

  test 'Zusammenfuehren zieht Coach-Boegen und erhaltene Bewertungen auf das Masterprofil' do
    master = create(:referee)
    secondary = create(:referee)
    written = create(:referee_observation, :with_rating, coach: secondary)
    received = create(:referee_observation, :with_rating, rated_referee: secondary)

    secondary.merge_into!(master)

    assert_equal master.id, written.reload.coach_id
    assert_equal master.id, received.ratings.first.reload.referee_id
  end

  test 'Zusammenfuehren ueberspringt einen Bogen, den das Masterprofil zum selben Spiel schon hat' do
    master = create(:referee)
    secondary = create(:referee)
    game = create(:game)
    kept = create(:referee_observation, :with_rating, coach: master, game: game)
    duplicate = create(:referee_observation, :with_rating, coach: secondary, game: game)

    assert_nothing_raised { secondary.merge_into!(master) }

    assert RefereeObservation.exists?(kept.id)
    assert_not RefereeObservation.exists?(duplicate.id)
  end
end
