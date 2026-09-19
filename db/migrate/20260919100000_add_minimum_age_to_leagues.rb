class AddMinimumAgeToLeagues < ActiveRecord::Migration[7.2]
  def change
    add_column :leagues, :minimum_age, :integer,
               comment: 'Mindestalter in Jahren, tagesgenau am Tag der Lizenzbeantragung geprüft; ' \
                        'nil = keine Untergrenze. Unabhängig vom Stichtag (deadline/before_deadline).'
  end
end
