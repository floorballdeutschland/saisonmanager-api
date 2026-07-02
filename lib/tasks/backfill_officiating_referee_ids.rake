# frozen_string_literal: true

# Befüllt games.officiating_referee_ids (kanonische Referee-PKs der tatsächlich
# eingesetzten Schiedsrichter) für Bestandsspiele – aufgelöst über die
# Lizenznummer aus referee1/2_string bzw. der Live-Erfassung referee_ids.
# Idempotent; verarbeitet nur Spiele mit noch leerer Spalte. Für Neuerfassungen
# setzt GamesController#set_referee die PKs bereits direkt beim Eintragen.
#
#   bundle exec rails referees:backfill_officiating_ids
namespace :referees do
  desc 'games.officiating_referee_ids aus dem Spielbericht (Lizenznummer) befüllen'
  task backfill_officiating_ids: :environment do
    # Lizenz → PK einmalig laden (statt einer Query je Spiel).
    license_to_id = Referee.where.not(lizenznummer: nil).pluck(:lizenznummer, :id).to_h

    scope = Game.where.not(referee1_string: [nil, ''])
                .or(Game.where.not(referee2_string: [nil, '']))
                .or(Game.where('array_length(referee_ids, 1) > 0'))
                .where("officiating_referee_ids = '{}' OR officiating_referee_ids IS NULL")

    updated = 0
    scope.in_batches(of: 500) do |batch|
      batch.each do |game|
        ids = game.officiating_referee_licenses.map { |lic| (lic && license_to_id[lic]) || 0 }
        next if ids.all?(&:zero?)

        game.update_columns(officiating_referee_ids: ids)
        updated += 1
      end
    end

    puts "officiating_referee_ids Backfill: #{updated} Spiel(e) aktualisiert."
  end
end
