# frozen_string_literal: true

# 用户收藏夹控制器
# 提供收藏 CRUD 和同步操作
class Client::User::FavoritesController < ::Client::ProtectedController
  # 获取收藏列表
  # GET /api/user/favorites
  def index
    favorites = User::FavoriteService.list_favorites(current_user)
    render_success(favorites)
  end

  # 同步收藏（替换式）
  # PUT /api/user/favorites
  def sync
    item_ids = params[:item_ids] || params[:itemIds] || params[:favorites] || []

    unless item_ids.is_a?(Array)
      return render_error('item_ids 必须是一个数组', :bad_request)
    end

    item_ids = item_ids.reject(&:blank?)

    favorites = User::FavoriteService.sync_favorites(current_user, item_ids)
    render_success(favorites)
  end

  # 添加收藏
  # POST /api/user/favorites/:item_id
  def create
    item_id = params[:item_id]

    if item_id.blank?
      return render_error('item_id 不能为空', :bad_request)
    end

    favorite = User::FavoriteService.add_favorite(current_user, item_id)
    render_success({ item_id: favorite.item_id, created_at: favorite.created_at }, '添加收藏成功')
  end

  # 移除收藏
  # DELETE /api/user/favorites/:item_id
  def destroy
    item_id = params[:item_id]

    if item_id.blank?
      return render_error('item_id 不能为空', :bad_request)
    end

    removed = User::FavoriteService.remove_favorite(current_user, item_id)

    if removed
      render_success(nil, '移除收藏成功')
    else
      render_error('收藏记录不存在', :not_found)
    end
  end

  # 切换收藏状态
  # POST /api/user/favorites/:item_id/toggle
  def toggle
    item_id = params[:item_id]

    if item_id.blank?
      return render_error('item_id 不能为空', :bad_request)
    end

    is_favorited = User::FavoriteService.toggle_favorite(current_user, item_id)
    message = is_favorited ? '添加收藏成功' : '移除收藏成功'

    render_success({ favorited: is_favorited }, message)
  end

  # 批量添加收藏
  # POST /api/user/favorites/batch
  def batch_add
    item_ids = params[:item_ids] || params[:itemIds] || params[:favorites] || []

    unless item_ids.is_a?(Array)
      return render_error('item_ids 必须是一个数组', :bad_request)
    end

    item_ids = item_ids.reject(&:blank?)
    favorites = User::FavoriteService.add_favorites(current_user, item_ids)

    render_success(
      favorites.map { |f| { item_id: f.item_id, created_at: f.created_at } },
      "成功添加 #{favorites.length} 个收藏"
    )
  end

  # 清空收藏
  # DELETE /api/user/favorites
  def clear
    count = User::FavoriteService.clear_favorites(current_user)
    render_success({ deleted_count: count }, '清空收藏成功')
  end

  # 获取收藏数量
  # GET /api/user/favorites/count
  def count
    count = User::FavoriteService.favorites_count(current_user)
    render_success({ count: count })
  end
end
