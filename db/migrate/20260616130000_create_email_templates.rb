class CreateEmailTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :email_templates do |t|
      t.string :mailer_class, null: false, comment: 'z. B. RefereeMailer'
      t.string :action_name, null: false, comment: 'z. B. published_assignment_notification'
      t.string :locale, null: false, default: 'de'
      t.string :subject
      t.text :body, comment: 'Optionaler HTML-Body mit {{platzhalter}}; leer = Code-Default (ERB-View)'
      t.string :from_address
      t.string :reply_to_address
      t.timestamps
    end

    add_index :email_templates, %i[mailer_class action_name locale], unique: true,
                                                                      name: 'index_email_templates_on_key'
  end
end
