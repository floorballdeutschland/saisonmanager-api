# Der Waechter meldete eine nie eingeloeste Zusage bei JEDEM Lauf erneut, alle
# fuenf Minuten und ohne Ende. 16 alte Zusagen erzeugten so ueber 3700
# Sentry-Ereignisse und frassen das Kontingent, das sich API und Frontend
# teilen. Mit dem Stempel wird jede Zusage genau einmal gemeldet.
class AddOverdueReportedAtToStreamBroadcasts < ActiveRecord::Migration[7.2]
  def change
    add_column :stream_broadcasts, :overdue_reported_at, :datetime,
               comment: 'Offene Zusage einmal gemeldet (StreamWatchdog#melde_offene_zusagen)'
  end
end
