class AddReportFormEmailEnabledToStateAssociations < ActiveRecord::Migration[7.1]
  def change
    add_column :state_associations, :report_form_email_enabled, :boolean, null: false, default: false,
                                                                          comment: 'Wenn true: Berichtsformular des ' \
                                                                                   'Schiris wird per E-Mail an die ' \
                                                                                   'VSK versendet'
  end
end
