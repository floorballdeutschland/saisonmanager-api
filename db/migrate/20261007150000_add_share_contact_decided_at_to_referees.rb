class AddShareContactDecidedAtToReferees < ActiveRecord::Migration[7.2]
  def change
    # Nachweis der Einwilligung (Art. 7 Abs. 1 DSGVO): Zeitpunkt der letzten
    # Entscheidung, gesetzt bei Erteilung UND Widerruf. Referees haben kein
    # PaperTrail, ohne diese Spalte waere der Zeitpunkt nicht belegbar.
    add_column :referees, :share_contact_decided_at, :datetime,
               comment: 'Zeitpunkt der letzten Entscheidung zu share_contact_with_officials ' \
                        '(Zustimmung oder Widerruf). NULL = noch nicht entschieden.'
  end
end
