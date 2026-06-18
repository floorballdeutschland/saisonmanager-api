FactoryBot.define do
  factory :user do
    sequence(:user_name) { |n| "user#{n}" }
    sequence(:first_name) { |n| "First#{n}" }
    sequence(:last_name) { |n| "Last#{n}" }
    password { 'password123' }
    permissions { [] }

    # user_group_id: 1 Admin · 2 SBK · 3 RSK · 4 VM · 5 TM · 6 Schiri · 7 Ansetzer.
    # game_operation_id == 0 → globale Berechtigung über alle Verbände.

    trait :admin do
      permissions { [{ 'user_group_id' => 1, 'game_operation_id' => 0 }] }
    end

    trait :rsk_scoped do
      transient { game_operation_id { 1 } }
      permissions { [{ 'user_group_id' => 3, 'game_operation_id' => game_operation_id }] }
    end

    trait :assigner_scoped do
      transient { game_operation_id { 1 } }
      permissions { [{ 'user_group_id' => 7, 'game_operation_id' => game_operation_id }] }
    end

    trait :sbk_global do
      permissions { [{ 'user_group_id' => 2, 'game_operation_id' => 0 }] }
    end

    trait :sbk_scoped do
      transient { game_operation_id { 1 } }
      permissions { [{ 'user_group_id' => 2, 'game_operation_id' => game_operation_id }] }
    end

    trait :vm do
      transient { club_id { 1 } }
      permissions { [{ 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => club_id }] }
    end

    trait :tm do
      transient { team_id { 1 } }
      teams { [team_id] }
      permissions { [{ 'user_group_id' => 5, 'game_operation_id' => 0 }] }
    end
  end
end
