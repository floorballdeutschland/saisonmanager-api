require 'test_helper'

class TemplatedMailerTest < ActiveSupport::TestCase
  PLACEHOLDER_PATTERN = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/

  test 'jeder Katalog-Eintrag hat die Pflichtfelder' do
    EmailTemplateCatalog.entries.each do |entry|
      assert entry[:mailer_class].present?, "mailer_class fehlt bei #{entry.inspect}"
      assert entry[:action_name].present?, "action_name fehlt bei #{entry.inspect}"
      assert entry[:default_subject].present?, "default_subject fehlt bei #{entry[:mailer_class]}##{entry[:action_name]}"
      assert_kind_of Array, entry[:placeholders], "placeholders muss Array sein bei #{entry[:mailer_class]}##{entry[:action_name]}"
    end
  end

  test 'Key entspricht mailer_class#action_name' do
    EmailTemplateCatalog::ENTRIES.each do |key, entry|
      assert_equal "#{entry[:mailer_class]}##{entry[:action_name]}", key
    end
  end

  test 'jeder Platzhalter im default_subject ist in placeholders deklariert' do
    EmailTemplateCatalog.entries.each do |entry|
      declared = entry[:placeholders].map { |p| p[:key].to_s }
      used = entry[:default_subject].scan(PLACEHOLDER_PATTERN).flatten
      missing = used - declared
      assert_empty missing,
                   "Undeklarierte Platzhalter #{missing.inspect} im Betreff von #{entry[:mailer_class]}##{entry[:action_name]}"
    end
  end

  test 'jeder deklarierte Platzhalter hat key und description' do
    EmailTemplateCatalog.entries.each do |entry|
      entry[:placeholders].each do |placeholder|
        assert placeholder[:key].present?, "Platzhalter ohne key bei #{entry[:mailer_class]}##{entry[:action_name]}"
        assert placeholder[:description].present?, "Platzhalter #{placeholder[:key]} ohne description bei #{entry[:mailer_class]}##{entry[:action_name]}"
      end
    end
  end
end
