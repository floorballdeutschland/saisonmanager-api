require 'test_helper'

class ProceedingProposalTest < ActiveSupport::TestCase
  test 'ungültiger Status ist nicht valide' do
    proposal = ProceedingProposal.new(status: 'bogus')
    assert_not proposal.valid?
    assert proposal.errors[:status].present?
  end

  test 'pending-Scope liefert nur offene Vorschläge' do
    go = GameOperation.create!(name: 'GO', short_name: 'GO')
    league = League.create!(game_operation: go, name: 'Liga', season_id: '18', table_modus: 'classic')
    club = Club.create!
    arena = Arena.create!(name: 'Halle', city: 'Stadt')
    sa = StateAssociation.create!(name: 'LV')
    gd = GameDay.create!(league: league, arena: arena, club: club, number: 1, date: '2026-02-01')
    home = Team.create!(league: league, club: club, name: 'H')
    guest = Team.create!(league: league, club: club, name: 'G')
    game = Game.create!(game_day: gd, home_team: home, guest_team: guest, forfait: 0,
                        overtime: false, legacy: false, events: [], players: { 'home' => [], 'guest' => [] })
    open_proposal = ProceedingProposal.create!(game: game, state_association: sa, status: 'pending')
    game2 = Game.create!(game_day: gd, home_team: home, guest_team: guest, forfait: 0,
                         overtime: false, legacy: false, events: [], players: { 'home' => [], 'guest' => [] })
    ProceedingProposal.create!(game: game2, state_association: sa, status: 'opened')

    assert_equal [open_proposal.id], ProceedingProposal.pending.pluck(:id)
    assert_equal go.id, open_proposal.game_operation_id
  end
end
