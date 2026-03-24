# frozen_string_literal: true

module Accounts
  # 用户收藏夹项模型
  # 每条收藏一行，project 列由 DB default 填充
  class UserFavoriteItem < ApplicationRecord
    # ============================================
    # 关联
    # ============================================
    belongs_to :user, foreign_key: :user_id, class_name: 'Accounts::User'

    # ============================================
    # 验证
    # ============================================
    validates :user_id, presence: true
    validates :item_id, presence: true

    # ============================================
    # 作用域
    # ============================================
    scope :for_user, ->(user_id) { where(user_id: user_id) }

    # ============================================
    # 类方法
    # ============================================

    # 检查是否已收藏
    def self.favorited?(user_id, item_id)
      exists?(user_id: user_id, item_id: item_id)
    end

    # 获取用户的收藏列表
    def self.favorites_for_user(user_id)
      where(user_id: user_id).order(created_at: :desc).pluck(:item_id)
    end

    # 替换式同步收藏列表
    def self.sync_favorites(user_id, item_ids)
      transaction do
        where(user_id: user_id).delete_all

        items = item_ids.map do |item_id|
          { user_id: user_id, item_id: item_id, created_at: Time.current, updated_at: Time.current }
        end
        insert_all(items) if items.any?
      end
    end
  end
end
