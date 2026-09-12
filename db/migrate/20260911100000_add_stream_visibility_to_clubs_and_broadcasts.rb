# frozen_string_literal: true

# Die Zusage an einzelne Ausrichter: Ihr Spiel laeuft bei uns waehrend der
# Uebertragung NICHT oeffentlich, sondern "nicht gelistet" -- sie senden selbst
# und betreiben dort ihr Marketing. Nach dem Spiel soll die Aufzeichnung
# trotzdem oeffentlich auf dem Verbandskanal stehen.
#
# AM VEREIN UND NICHT AN DER MANNSCHAFT, obwohl der Streamschluessel an der
# Mannschaft haengt: Der Schluessel ist eine technische Angabe, die YouTube je
# Mannschaft ausgegeben hat. Die Zusage ist eine Absprache mit dem VEREIN und
# gilt, "wenn er ausrichtet" -- Ausrichter ist `game_days.club_id`. Eine
# Mannschaft entsteht ausserdem jede Saison neu; ein Flag an ihr fiele beim
# ersten vergessenen Kopierschritt still auf "oeffentlich" zurueck, und still
# oeffentlich ist genau der Schaden, den die Zusage verhindern soll.
#
# `promote_to_public` am Uebertragungssatz statt einer Ableitung zur Laufzeit:
# Der Waechter muss Monate spaeter noch wissen, ob DIESE Uebertragung wegen
# einer Zusage nicht gelistet ist oder weil jemand sie bewusst so angelegt hat
# (Probelauf, interne Aufzeichnung). Wird die Zusage zwischendurch abgewaehlt,
# darf das die bereits laufende Uebertragung nicht umdeuten.
class AddStreamVisibilityToClubsAndBroadcasts < ActiveRecord::Migration[7.2]
  def change
    add_column :clubs, :stream_default_unlisted, :boolean, default: false, null: false

    add_column :stream_broadcasts, :promote_to_public, :boolean, default: false, null: false
    add_column :stream_broadcasts, :promoted_at, :datetime

    # Der Waechter fragt alle fuenf Minuten "was ist faellig". Ohne Index ist das
    # ein Full Scan ueber eine Tabelle, die mit jeder Saison waechst.
    add_index :stream_broadcasts, %i[promote_to_public promoted_at],
              where: 'promote_to_public AND promoted_at IS NULL',
              name: 'index_stream_broadcasts_auf_faellige_veroeffentlichung'
  end
end
