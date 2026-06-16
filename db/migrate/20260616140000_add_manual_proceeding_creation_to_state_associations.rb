class AddManualProceedingCreationToStateAssociations < ActiveRecord::Migration[7.1]
  def change
    add_column :state_associations, :manual_proceeding_creation, :boolean, null: false, default: false,
                                                                            comment: 'Wenn true: keine automatische ' \
                                                                                     'VSK-Mail, stattdessen ' \
                                                                                     'Verfahrensvorschlag an die SBK'
  end
end
