class AddFemaleOverageYearsToLeagues < ActiveRecord::Migration[7.2]
  def change
    add_column :leagues, :female_overage_years, :integer,
               comment: 'Overage-Regel: Spielerinnen (gender W) duerfen so viele Jahre aelter sein als der ' \
                        'Stichtag "geboren ab" erlaubt; nil = keine Ausnahme. Nur bei before_deadline = false.'
  end
end
