FactoryBot.define do
  factory :club do
    sequence(:name) { |n| "Club #{n}" }
    # Modulo, damit die Sequenz die Vier-Zeichen-Grenze (Club::SHORT_NAME_MAX)
    # auch in langen Laeufen nicht reisst.
    sequence(:short_name) { |n| "C#{n % 1000}" }
  end
end
