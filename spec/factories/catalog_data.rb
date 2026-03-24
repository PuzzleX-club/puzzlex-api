# frozen_string_literal: true

FactoryBot.define do
  factory :catalog_item, class: 'CatalogData::Item' do
    transient do
      sub_type { nil }
      quality { nil }
      talent_ids { nil }
      use_level { nil }
      wealth_value { nil }
      drop_scenes { nil }
      booth_fees { nil }
      destructible { nil }
      given_skill_id { nil }
      on_chain_delay { nil }
      resource_instructions { nil }
      token_task_level { nil }
      token_task_refresh_type { nil }
      user_type { nil }
    end

    item_id { Faker::Number.unique.between(from: 10_000, to: 99_999) }
    item_type { %w[weapon armor accessory consumable].sample }
    source_hash { SecureRandom.hex(32) }
    enabled { true }
    extra_data { {} }

    after(:build) do |item, evaluator|
      extensions = {
        'sub_type' => evaluator.sub_type,
        'quality' => evaluator.quality,
        'talent_ids' => evaluator.talent_ids,
        'use_level' => evaluator.use_level,
        'wealth_value' => evaluator.wealth_value,
        'drop_scenes' => evaluator.drop_scenes,
        'booth_fees' => evaluator.booth_fees,
        'destructible' => evaluator.destructible,
        'given_skill_id' => evaluator.given_skill_id,
        'on_chain_delay' => evaluator.on_chain_delay,
        'resource_instructions' => evaluator.resource_instructions,
        'token_task_level' => evaluator.token_task_level,
        'token_task_refresh_type' => evaluator.token_task_refresh_type,
        'user_type' => evaluator.user_type
      }.compact

      item.extra_data = item.extra_data.to_h.merge(extensions)
    end

    trait :with_translations do
      after(:create) do |item|
        create(:catalog_item_translation, item: item, locale: 'en')
        create(:catalog_item_translation, item: item, locale: 'zh')
      end
    end
  end

  factory :catalog_item_translation, class: 'CatalogData::ItemTranslation' do
    association :item, factory: :catalog_item
    locale { 'en' }
    name { Faker::Fantasy::Tolkien.character }
    description { Faker::Lorem.sentence }
    translation_hash { SecureRandom.hex(32) }
  end

  factory :catalog_recipe, class: 'CatalogData::Recipe' do
    recipe_id { Faker::Number.unique.between(from: 10_000, to: 99_999) }
    source_hash { SecureRandom.hex(32) }
    enabled { true }

    trait :with_materials do
      after(:create) do |recipe|
        3.times do
          item = create(:catalog_item)
          create(:catalog_recipe_material,
                 recipe: recipe,
                 item: item,
                 quantity: Faker::Number.between(from: 1, to: 5))
        end
      end
    end

    trait :with_products do
      after(:create) do |recipe|
        2.times do
          item = create(:catalog_item)
          create(:catalog_recipe_product,
                 recipe: recipe,
                 item: item,
                 quantity: Faker::Number.between(from: 1, to: 3))
        end
      end
    end

    trait :with_translations do
      after(:create) do |recipe|
        create(:catalog_recipe_translation, recipe: recipe, locale: 'en')
        create(:catalog_recipe_translation, recipe: recipe, locale: 'zh')
      end
    end
  end

  factory :catalog_recipe_translation, class: 'CatalogData::RecipeTranslation' do
    association :recipe, factory: :catalog_recipe
    locale { 'en' }
    name { Faker::Fantasy::Tolkien.character }
    description { Faker::Lorem.sentence }
    translation_hash { SecureRandom.hex(32) }
  end

  factory :catalog_recipe_material, class: 'CatalogData::RecipeMaterial' do
    association :recipe, factory: :catalog_recipe
    association :item, factory: :catalog_item
    quantity { Faker::Number.between(from: 1, to: 5) }
  end

  factory :catalog_recipe_product, class: 'CatalogData::RecipeProduct' do
    association :recipe, factory: :catalog_recipe
    association :item, factory: :catalog_item
    quantity { Faker::Number.between(from: 1, to: 3) }
    weight { Faker::Number.between(from: 1, to: 100) }
  end
end
