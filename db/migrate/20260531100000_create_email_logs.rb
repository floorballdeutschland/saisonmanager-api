class CreateEmailLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :email_logs do |t|
      t.string :recipient, null: false
      t.string :cc
      t.string :subject, null: false
      t.string :mailer_action
      t.datetime :sent_at, null: false

      t.timestamps
    end

    add_index :email_logs, :sent_at
  end
end
