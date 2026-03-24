# frozen_string_literal: true

module User
  # 用户收藏服务
  # 提供收藏夹的 CRUD 和同步操作
  class FavoriteService
    class << self
      # 获取用户收藏列表
      # @param user [Accounts::User] 用户对象
      # @return [Array<String>] 收藏的 item_id 列表
      def list_favorites(user)
        Accounts::UserFavoriteItem.favorites_for_user(user.id)
      end

      # 添加收藏
      # @param user [Accounts::User] 用户对象
      # @param item_id [String] 物品 ID
      # @return [Accounts::UserFavoriteItem] 创建的收藏记录
      def add_favorite(user, item_id)
        Accounts::UserFavoriteItem.find_or_create_by!(
          user_id: user.id,
          item_id: item_id
        )
      end

      # 移除收藏
      # @param user [Accounts::User] 用户对象
      # @param item_id [String] 物品 ID
      # @return [Boolean] 是否成功删除
      def remove_favorite(user, item_id)
        Accounts::UserFavoriteItem.where(
          user_id: user.id,
          item_id: item_id
        ).delete_all > 0
      end

      # 批量添加收藏
      # @param user [Accounts::User] 用户对象
      # @param item_ids [Array<String>] 物品 ID 列表
      # @return [Array<Accounts::UserFavoriteItem>] 创建的收藏记录列表
      def add_favorites(user, item_ids)
        existing_ids = list_favorites(user).to_set
        new_ids = item_ids.reject { |id| existing_ids.include?(id) }

        new_ids.map do |item_id|
          add_favorite(user, item_id)
        end
      end

      # 替换式同步收藏列表
      # @param user [Accounts::User] 用户对象
      # @param item_ids [Array<String>] 新的收藏列表
      # @return [Array<String>] 同步后的收藏列表
      def sync_favorites(user, item_ids)
        Accounts::UserFavoriteItem.sync_favorites(user.id, item_ids)
        item_ids
      end

      # 检查是否已收藏
      # @param user [Accounts::User] 用户对象
      # @param item_id [String] 物品 ID
      # @return [Boolean] 是否已收藏
      def favorited?(user, item_id)
        Accounts::UserFavoriteItem.favorited?(user.id, item_id)
      end

      # 切换收藏状态
      # @param user [Accounts::User] 用户对象
      # @param item_id [String] 物品 ID
      # @return [Boolean] 切换后的收藏状态（true=已收藏，false=未收藏）
      def toggle_favorite(user, item_id)
        if favorited?(user, item_id)
          remove_favorite(user, item_id)
          false
        else
          add_favorite(user, item_id)
          true
        end
      end

      # 清空用户收藏
      # @param user [Accounts::User] 用户对象
      # @return [Integer] 删除的记录数
      def clear_favorites(user)
        Accounts::UserFavoriteItem.for_user(user.id).delete_all
      end

      # 获取收藏数量
      # @param user [Accounts::User] 用户对象
      # @return [Integer] 收藏数量
      def favorites_count(user)
        Accounts::UserFavoriteItem.for_user(user.id).count
      end
    end
  end
end
