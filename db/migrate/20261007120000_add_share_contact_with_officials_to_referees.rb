class AddShareContactWithOfficialsToReferees < ActiveRecord::Migration[7.2]
  def change
    # Bewusst ohne Default: NULL heisst "noch nie gefragt" und loest im Portal
    # die einmalige Rueckfrage aus, false ist eine ausdrueckliche Ablehnung.
    add_column :referees, :share_contact_with_officials, :boolean,
               comment: 'Einwilligung: Telefonnummer und E-Mail sind fuer die am selben Spiel ' \
                        'angesetzten Schiris und den Coach sichtbar. NULL = noch nicht gefragt.'
  end
end
